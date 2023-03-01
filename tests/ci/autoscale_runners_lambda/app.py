#!/usr/bin/env python3

"""The lambda to decrease/increase ASG desired capacity based on current queue"""

import json
import logging
import time
from dataclasses import dataclass
from typing import Any, List, Optional

import boto3  # type: ignore
import requests  # type: ignore

RUNNER_TYPE_LABELS = [
    "builder",
    "func-tester",
    "func-tester-aarch64",
    "fuzzer-unit-tester",
    "stress-tester",
    "style-checker",
    "style-checker-aarch64",
]
QUEUE_QUERY = f"""SELECT
    last_status AS status,
    toUInt32(count()) AS length,
    labels
FROM
(
    SELECT
        arraySort(groupArray(status))[-1] AS last_status,
        labels,
        id,
        html_url
    FROM default.workflow_jobs
    WHERE has(labels, 'self-hosted')
        AND hasAny({RUNNER_TYPE_LABELS}, labels)
        AND started_at > now() - INTERVAL 2 DAY
    GROUP BY ALL
    HAVING last_status != 'completed'
)
GROUP BY ALL
ORDER BY labels, last_status"""


@dataclass
class Queue:
    status: str
    lentgh: int
    label: str


class CHException(Exception):
    pass


class ClickHouseHelper:
    def __init__(
        self,
        url: Optional[str] = None,
        user: Optional[str] = None,
        password: Optional[str] = None,
    ):
        self.url = url
        self.auth = {}
        if user:
            self.auth["X-ClickHouse-User"] = user
        if password:
            self.auth["X-ClickHouse-Key"] = password

    def _select_and_get_json_each_row(self, db, query):
        params = {
            "database": db,
            "query": query,
            "default_format": "JSONEachRow",
        }
        for i in range(5):
            response = None
            try:
                response = requests.get(self.url, params=params, headers=self.auth)
                response.raise_for_status()
                return response.text
            except Exception as ex:
                logging.warning("Cannot insert with exception %s", str(ex))
                if response:
                    logging.warning("Reponse text %s", response.text)
                time.sleep(0.1 * i)

        raise CHException("Cannot fetch data from clickhouse")

    def select_json_each_row(self, db, query):
        text = self._select_and_get_json_each_row(db, query)
        result = []
        for line in text.split("\n"):
            if line:
                result.append(json.loads(line))
        return result


def set_capacity(
    runner_type: str, queue: List[Queue], client: Any, dry_run: bool = True
) -> None:
    assert all(q.label == runner_type for q in queue)
    as_groups = client.describe_auto_scaling_groups(
        Filters=[
            {"Name": "tag-key", "Values": ["github:runner-type"]},
            {"Name": "tag-value", "Values": [runner_type]},
        ]
    )["AutoScalingGroups"]
    assert len(as_groups) == 1
    asg = as_groups[0]
    running = 0
    queued = 0
    for q in queue:
        if q.status == "in_progress":
            running = q.lentgh
        if q.status == "queued":
            queued = q.lentgh

    capacity_reserve = max(0, asg["DesiredCapacity"] - running)
    stop = False
    if queued:
        # This part is about scaling up
        # First, let's check if there's enough runners to cover the queue
        stop = stop or (asg["DesiredCapacity"] - running - queued) > 0

        stop = stop or asg["MaxSize"] <= asg["DesiredCapacity"]
        # Let's calculate a new desired capacity. Here the scale is used to not
        # scale up and down too quickly
        desired_capacity = asg["DesiredCapacity"] + ((queued - capacity_reserve) // 5)
        desired_capacity = min(desired_capacity, asg["MaxSize"])
        # Finally, should the capacity be even changed
        stop = stop or asg["DesiredCapacity"] == desired_capacity
        if stop:
            return
        print(
            f"The ASG {asg['AutoScalingGroupName']} capacity will be changed to "
            f"{desired_capacity}, current capacity={asg['DesiredCapacity']}, "
            f"maximum capacity={asg['MaxSize']}, running jobs={running}, "
            f"queue size={queued}"
        )
        if not dry_run:
            client.set_desired_capacity(
                AutoScalingGroupName=asg["AutoScalingGroupName"],
                DesiredCapacity=desired_capacity,
            )
        return

    # Now we will calculate if we need to scale down
    stop = stop or asg["DesiredCapacity"] <= asg["MinSize"]
    stop = stop or asg["DesiredCapacity"] <= running
    desired_capacity = asg["DesiredCapacity"] - (capacity_reserve // 3)
    desired_capacity = max(desired_capacity, asg["MinSize"])
    stop = stop or asg["DesiredCapacity"] == desired_capacity
    if stop:
        return

    print(
        f"The ASG {asg['AutoScalingGroupName']} capacity will be changed to "
        f"{desired_capacity}, current capacity={asg['DesiredCapacity']}, "
        f"maximum capacity={asg['MaxSize']}, running jobs={running}, "
        f"queue size={queued}"
    )
    if not dry_run:
        client.set_desired_capacity(
            AutoScalingGroupName=asg["AutoScalingGroupName"],
            DesiredCapacity=desired_capacity,
        )


def main(dry_run: bool = True) -> None:
    asg_client = boto3.client("autoscaling")
    ch_client = ClickHouseHelper("https://play.clickhouse.com/", "play")
    queues = ch_client.select_json_each_row("default", QUEUE_QUERY)
    for runner_type in RUNNER_TYPE_LABELS:
        queue = [
            Queue(queue["status"], queue["length"], runner_type)
            for queue in queues
            if runner_type in queue["labels"]
        ]
        set_capacity(runner_type, queue, asg_client, dry_run)


def handler(event: dict, context: Any) -> None:
    _ = event
    _ = context
    return main(False)
