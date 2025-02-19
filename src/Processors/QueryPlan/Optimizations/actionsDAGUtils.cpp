#include <Processors/QueryPlan/Optimizations/actionsDAGUtils.h>

#include <Core/Field.h>
#include <Functions/IFunction.h>

#include <stack>

namespace DB
{
MatchedTrees::Matches matchTrees(const ActionsDAG & inner_dag, const ActionsDAG & outer_dag)
{
    using Parents = std::set<const ActionsDAG::Node *>;
    std::unordered_map<const ActionsDAG::Node *, Parents> inner_parents;
    std::unordered_map<std::string_view, const ActionsDAG::Node *> inner_inputs_and_constants;

    {
        std::stack<const ActionsDAG::Node *> stack;
        for (const auto * out : inner_dag.getOutputs())
        {
            if (inner_parents.contains(out))
                continue;

            stack.push(out);
            inner_parents.emplace(out, Parents());
            while (!stack.empty())
            {
                const auto * node = stack.top();
                stack.pop();

                if (node->type == ActionsDAG::ActionType::INPUT || node->type == ActionsDAG::ActionType::COLUMN)
                    inner_inputs_and_constants.emplace(node->result_name, node);

                for (const auto * child : node->children)
                {
                    auto [it, inserted] = inner_parents.emplace(child, Parents());
                    it->second.emplace(node);

                    if (inserted)
                        stack.push(child);
                }
            }
        }
    }

    struct Frame
    {
        const ActionsDAG::Node * node;
        ActionsDAG::NodeRawConstPtrs mapped_children;
    };

    MatchedTrees::Matches matches;
    std::stack<Frame> stack;

    for (const auto & node : outer_dag.getNodes())
    {
        if (matches.contains(&node))
            continue;

        stack.push(Frame{&node, {}});
        while (!stack.empty())
        {
            auto & frame = stack.top();
            frame.mapped_children.reserve(frame.node->children.size());

            while (frame.mapped_children.size() < frame.node->children.size())
            {
                const auto * child = frame.node->children[frame.mapped_children.size()];
                auto it = matches.find(child);
                if (it == matches.end())
                {
                    /// If match map does not contain a child, it was not visited.
                    stack.push(Frame{child, {}});
                    break;
                }
                /// A node from found match may be nullptr.
                /// It means that node is visited, but no match was found.
                frame.mapped_children.push_back(it->second.node);
            }

            if (frame.mapped_children.size() < frame.node->children.size())
                continue;

            /// Create an empty match for current node.
            /// match.node will be set if match is found.
            auto & match = matches[frame.node];

            if (frame.node->type == ActionsDAG::ActionType::INPUT || frame.node->type == ActionsDAG::ActionType::COLUMN)
            {
                const ActionsDAG::Node * mapped = nullptr;
                if (auto it = inner_inputs_and_constants.find(frame.node->result_name); it != inner_inputs_and_constants.end())
                    mapped = it->second;

                match.node = mapped;
            }
            else if (frame.node->type == ActionsDAG::ActionType::ALIAS)
            {
                match = matches[frame.node->children.at(0)];
            }
            else if (frame.node->type == ActionsDAG::ActionType::FUNCTION)
            {
                //std::cerr << "... Processing " << frame.node->function_base->getName() << std::endl;

                bool found_all_children = true;
                for (const auto * child : frame.mapped_children)
                    if (!child)
                        found_all_children = false;

                if (found_all_children && !frame.mapped_children.empty())
                {
                    Parents container;
                    Parents * intersection = &inner_parents[frame.mapped_children[0]];

                    if (frame.mapped_children.size() > 1)
                    {
                        std::vector<Parents *> other_parents;
                        size_t mapped_children_size = frame.mapped_children.size();
                        other_parents.reserve(mapped_children_size);
                        for (size_t i = 1; i < mapped_children_size; ++i)
                            other_parents.push_back(&inner_parents[frame.mapped_children[i]]);

                        for (const auto * parent : *intersection)
                        {
                            bool is_common = true;
                            for (const auto * set : other_parents)
                            {
                                if (!set->contains(parent))
                                {
                                    is_common = false;
                                    break;
                                }
                            }

                            if (is_common)
                                container.insert(parent);
                        }

                        intersection = &container;
                    }

                    //std::cerr << ".. Candidate parents " << intersection->size() << std::endl;

                    if (!intersection->empty())
                    {
                        auto func_name = frame.node->function_base->getName();
                        for (const auto * parent : *intersection)
                        {
                            //std::cerr << ".. candidate " << parent->result_name << std::endl;
                            if (parent->type == ActionsDAG::ActionType::FUNCTION && func_name == parent->function_base->getName())
                            {
                                const auto & children = parent->children;
                                size_t num_children = children.size();
                                if (frame.mapped_children.size() == num_children)
                                {
                                    bool all_children_matched = true;
                                    for (size_t i = 0; all_children_matched && i < num_children; ++i)
                                        all_children_matched = frame.mapped_children[i] == children[i];

                                    if (all_children_matched)
                                    {
                                        match.node = parent;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }

                if (!match.node && frame.node->function_base->hasInformationAboutMonotonicity())
                {
                    size_t num_const_args = 0;
                    const ActionsDAG::Node * monotonic_child = nullptr;
                    for (const auto * child : frame.node->children)
                    {
                        if (child->column)
                            ++num_const_args;
                        else
                            monotonic_child = child;
                    }

                    if (monotonic_child && num_const_args + 1 == frame.node->children.size())
                    {
                        const auto & child_match = matches[monotonic_child];
                        if (child_match.node)
                        {
                            auto info = frame.node->function_base->getMonotonicityForRange(*monotonic_child->result_type, {}, {});
                            if (info.is_monotonic)
                            {
                                MatchedTrees::Monotonicity monotonicity;
                                monotonicity.direction *= info.is_positive ? 1 : -1;
                                monotonicity.strict = info.is_strict;

                                if (child_match.monotonicity)
                                {
                                    monotonicity.direction *= child_match.monotonicity->direction;
                                    if (!child_match.monotonicity->strict)
                                        monotonicity.strict = false;
                                }

                                match.node = child_match.node;
                                match.monotonicity = monotonicity;
                            }
                        }
                    }
                }
            }

            stack.pop();
        }
    }

    return matches;
}


}
