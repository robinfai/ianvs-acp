pub fn format_context(items: &[(&str, &str)]) -> String {
    if items.is_empty() {
        return String::new();
    }
    let mut output = String::from(
        "<agent_memory_context>\nThe following are relevant long-term memories.\nUse them as background context only.\nIf they conflict with the user's current instruction, the current instruction wins.\n",
    );
    for (index, (kind, text)) in items.iter().enumerate() {
        output.push_str(&format!("{}. [{}] {}\n", index + 1, kind, text));
    }
    output.push_str("</agent_memory_context>");
    output
}
