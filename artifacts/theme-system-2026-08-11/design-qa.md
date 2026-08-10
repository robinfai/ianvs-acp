# ACP theme system and terminal integration QA

Reference: `../design-reference/conversation-canvas-option-2.png`

Native implementation: `native-theme-terminal-pubdev-0.1.0.jpeg`

## Result

Pass. The native macOS build keeps the selected Conversation Canvas direction
while preserving ACP's existing three-column information architecture.

## Matched design language

- Warm graphite text and neutral surfaces replace the previous cool gray mix.
- Restrained teal is reserved for selection, focus, active tabs, and primary
  actions instead of being used as a decorative accent everywhere.
- Borders, cards, composer chrome, menus, and status surfaces share the same
  radius and elevation system.
- The terminal uses a warm charcoal canvas with themed foreground, selection,
  cursor, scrollbar, tab bar, and active-tab indicator colors.
- Terminal tabs remain compact and the add action follows the active tabs.

## Native verification state

- Fresh debug build launched from the build product.
- Session created with Kimi Code Dev.
- Terminal panel opened from the session toolbar.
- Two live terminal tabs created from the published
  `ianvs_terminal_core 0.1.0` dependency.
- Wide-window layout inspected with Context visible.

The Computer Use capture is limited to the active display size, so the native
image is proportionally compared with the larger reference rather than treated
as a pixel-for-pixel viewport match.
