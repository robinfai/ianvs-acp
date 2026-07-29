pub struct ContextItem<'a> {
    pub kind: &'a str,
    pub scope: Option<&'a str>,
    pub text: &'a str,
    pub pinned: bool,
}

#[derive(Clone, Copy)]
pub struct ProfileBlock {
    pub label: &'static str,
    pub description: &'static str,
    pub limit: usize,
}

pub fn profile_block_for(kind: &str, scope: Option<&str>) -> Option<ProfileBlock> {
    match (kind, scope.unwrap_or("").trim()) {
        ("user_preference", "global") => Some(ProfileBlock {
            label: "user_profile",
            description: "Stable user preferences and identity facts.",
            limit: 4,
        }),
        ("project_rule" | "architecture_decision", "workspace") => Some(ProfileBlock {
            label: "workspace_profile",
            description: "Stable workspace rules and architecture decisions.",
            limit: 4,
        }),
        ("project_rule" | "architecture_decision", "repo") => Some(ProfileBlock {
            label: "project_profile",
            description: "Stable project rules and architecture decisions.",
            limit: 4,
        }),
        _ => None,
    }
}

pub fn format_context(items: &[(&str, &str)]) -> String {
    let context_items = items
        .iter()
        .map(|(kind, text)| ContextItem {
            kind,
            scope: None,
            text,
            pinned: false,
        })
        .collect::<Vec<_>>();
    format_context_items(&context_items, 4)
}

pub fn format_context_items(items: &[ContextItem<'_>], pinned_profile_limit: usize) -> String {
    if items.is_empty() {
        return String::new();
    }
    let mut pinned_candidates = Vec::new();
    let mut retrieved = Vec::new();
    for item in items {
        if item.pinned {
            pinned_candidates.push(item);
        } else {
            retrieved.push(item);
        }
    }
    let pinned_profile = select_pinned_profile(&pinned_candidates, pinned_profile_limit);
    if pinned_profile.is_empty() && retrieved.is_empty() {
        return String::new();
    }
    let mut output = String::from(
        "<agent_memory_context>\nThe following are relevant long-term memories.\nUse them as background context only.\nIf they conflict with the user's current instruction, the current instruction wins.\n",
    );
    if !pinned_profile.is_empty() {
        output.push_str(
            "<profile_memory>\nStable memory blocks that should stay available across turns.\n",
        );
        write_profile_blocks(&mut output, &pinned_profile);
        write_items(&mut output, &pinned_profile);
        output.push_str("</profile_memory>\n");
    }
    if !retrieved.is_empty() {
        output.push_str("<retrieved_memory>\nMemories retrieved for this turn.\n");
        write_items(&mut output, &retrieved);
        output.push_str("</retrieved_memory>\n");
    }
    output.push_str("</agent_memory_context>");
    output
}

fn select_pinned_profile<'a>(
    items: &[&'a ContextItem<'a>],
    limit: usize,
) -> Vec<&'a ContextItem<'a>> {
    if items.is_empty() || limit == 0 {
        return Vec::new();
    }
    let mut selected = Vec::<&ContextItem<'_>>::new();
    let mut selected_indexes = Vec::<usize>::new();
    let mut selected_by_block = Vec::<(String, usize)>::new();
    let mut seen_blocks = Vec::<String>::new();

    for (index, item) in items.iter().enumerate() {
        if selected.len() >= limit {
            break;
        }
        let block_key = profile_block_key(item);
        if seen_blocks.contains(&block_key) {
            continue;
        }
        seen_blocks.push(block_key);
        select_pinned_item(
            &mut selected,
            &mut selected_indexes,
            &mut selected_by_block,
            index,
            item,
        );
    }

    for (index, item) in items.iter().enumerate() {
        if selected.len() >= limit {
            break;
        }
        if selected_indexes.contains(&index) {
            continue;
        }
        let block_key = profile_block_key(item);
        let block_count = selected_by_block
            .iter()
            .find(|(key, _)| key == &block_key)
            .map(|(_, count)| *count)
            .unwrap_or(0);
        if block_count >= profile_block_limit(item, limit) {
            continue;
        }
        select_pinned_item(
            &mut selected,
            &mut selected_indexes,
            &mut selected_by_block,
            index,
            item,
        );
    }

    selected
}

fn select_pinned_item<'a>(
    selected: &mut Vec<&'a ContextItem<'a>>,
    selected_indexes: &mut Vec<usize>,
    selected_by_block: &mut Vec<(String, usize)>,
    index: usize,
    item: &'a ContextItem<'a>,
) {
    selected.push(item);
    selected_indexes.push(index);
    let block_key = profile_block_key(item);
    if let Some((_, count)) = selected_by_block
        .iter_mut()
        .find(|(key, _)| key == &block_key)
    {
        *count += 1;
    } else {
        selected_by_block.push((block_key, 1));
    }
}

fn profile_block_key(item: &ContextItem<'_>) -> String {
    if let Some(block) = profile_block_for(item.kind, item.scope) {
        return block.label.to_string();
    }
    match item.scope {
        Some(scope) if !scope.trim().is_empty() => format!("{}/{}", item.kind, scope.trim()),
        _ => format!("{}/unspecified", item.kind),
    }
}

fn profile_block_limit(item: &ContextItem<'_>, fallback: usize) -> usize {
    profile_block_for(item.kind, item.scope)
        .map(|block| block.limit)
        .unwrap_or(fallback)
}

fn write_profile_blocks(output: &mut String, items: &[&ContextItem<'_>]) {
    let mut seen = Vec::<&str>::new();
    for item in items {
        if let Some(block) = profile_block_for(item.kind, item.scope) {
            if seen.contains(&block.label) {
                continue;
            }
            seen.push(block.label);
            output.push_str(&format!("Block {}: {}\n", block.label, block.description));
        }
    }
}

fn write_items(output: &mut String, items: &[&ContextItem<'_>]) {
    for (index, item) in items.iter().enumerate() {
        output.push_str(&format!(
            "{}. [{}] {}\n",
            index + 1,
            item_label(item),
            item.text
        ));
    }
}

fn item_label(item: &ContextItem<'_>) -> String {
    let base_label = match item.scope {
        Some(scope) if !scope.trim().is_empty() => format!("{}/{}", item.kind, scope),
        _ => item.kind.to_string(),
    };
    if item.pinned {
        if let Some(block) = profile_block_for(item.kind, item.scope) {
            return format!("{}:{}", block.label, base_label);
        }
    }
    base_label
}
