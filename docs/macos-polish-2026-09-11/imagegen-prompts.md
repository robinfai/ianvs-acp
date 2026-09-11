# ImageGen reference prompts

## Supplementary MCP editor

Use case: ui-mockup. macOS ACP settings detail polish. Image 1 is the existing MCP editor with inconsistent floating labels. Image 2 is the already refined sibling Agent editor and is the visual contract. Generate one faithful polished MCP editor reference, preserve the original entire application window and content from image1. Match image2: 13pt regular persistent external labels aligned to a common column, fields share the same left edge, 12pt secondary descriptions,28-32pt desktop input height,12-16pt vertical field rhythm,24pt page insets,Add arguments and Add variable align with the field column. Name, connection type,command and arguments have clear consistent label placement, no leading icons inside these primary input fields. Keep navigation, neutral light surfaces,blue accent,Chinese UI,read-only status, real existing data; no new controls or features and no mobile or decorative styling. This is a practical source refinement reference, not behavior verification.

Mode: built-in `image_gen`, edits grounded in the `before/` native captures. No CLI fallback. Generated designs are references; final behavior is checked in Flutter and the native app.

## Settings

Use case: ui-mockup
Asset type: macOS UI refinement reference, not a new product concept.
Input images: 1 Agent settings, 2 permission settings, 3 assistant settings, 4 storage settings. All four are current app screenshots and edit targets.
Primary request: produce ONE high-resolution 2x2 board showing the SAME four existing ACP Client screens, subtly polished according to macOS Human Interface Guidelines. Preserve navigation architecture, information, existing functionality, positions of the major panes, light neutral palette and blue accent.
Focus on precise typography, control density, alignment, padding and margins. Use SF Pro-like macOS typography: 13pt regular field labels and controls, 12pt readable secondary descriptions with ~16pt line height, 15pt semibold section title, 17pt page title. Shared field heights approx 28-30pt, consistent 12pt label/control gaps; compact desktop buttons but not crowded. Form labels aligned to the same column. Give every switch row sufficient 8pt vertical breathing room and align switch center with title/description block. Do not duplicate On/Off descriptions under switches when the switch already communicates state. Related rows are closer than independent sections; 20-24pt section separation, 20-24pt page inset. Properly aligned disclosure chevron and heading; helper text aligns with field. A consistent restrained form surface, dividers, label style and input padding across every screen. Long local paths wrap or truncate safely.
Each quadrant should show a complete comparable application window (not cropped) with a tiny numbered caption outside the app. Maintain text/content from images; do not add product features, cards for decoration, large marketing typography, sidebar categories, heavy shadows or oversized radii. This is detailed macOS polishing, not iOS touch styling. Favor accurate readable Chinese. No watermark.


## Workspace

Use case: ui-mockup
Asset type: macOS application detailed refinement reference.
Input images: 1 current ACP main workspace, 2 tool/directory settings, 3 Agent menu, 4 independent LLM connection page. All are edit targets.
Produce ONE 2x2 high-resolution board of the SAME four complete screens, with subtle concrete macOS polish to typography, spacing and component details. Keep all existing panes, content, function and neutral light colors with blue accent. Preserve compact desktop design, not an iOS or marketing redesign.
Main workspace: coherent 13pt sidebar items and toolbar controls, 12pt metadata, 17pt primary empty-state title; align sidebar icons and label baselines, use 32-36pt nav rows with 8pt horizontal inner spacing, section labels subdued. Inspector rows align, consistent 16-20pt insets. Composer retains its document-reading space, restrained 8pt radius and no decorative shadow. Toolbar controls share a consistent 28-32pt target and align to native titlebar, prioritizing content.
Tool settings: 20-24pt content inset, clear 15pt title, 12pt helper text with 16pt line height, clear Add control aligned on title baseline, restrained empty state.
Agent menu: icon leading column, 13pt labels,12pt ellipsized paths, regular row padding and inset dividers, small 11pt section heading. Preserve menu structure.
LLM page: fix the back button overlapping macOS traffic lights. Reserve leftmost 88pt for native controls in the 52pt top toolbar and put back navigation/title to its right. Connection form should use persistent external labels above fields,13pt labels,12pt helper, uniform30pt fields,12-16pt field gaps,17pt heading. Right-align the primary start button rather than full width. Form max-width around480pt and20pt outer margin.
No new routes or features, no decorative cards, no icons replacing real content, no arbitrary colors, no phone frames. Each quadrant tiny numbered caption outside window. Prioritize precise readable macOS feel.


## Dialogs

Use case: ui-mockup
Asset type: macOS dialogs and inspector detail polishing reference.
Input images: 1 Activity & Diagnostics Events, 2 Permissions tab, 3 Runtime tab, 4 New Session dialog; all four current screenshots are edit targets.
Create ONE 2x2 high-resolution board of these exact four application states with fine macOS UI refinement. Show full windows, preserve all functionality, tab labels, wording, neutral white/gray palette and blue accent. Keep major dialog sizes and layout architecture. This is component typography and padding polish, not a new design concept.
Use a coherent 17pt semibold dialog heading with 12pt secondary context, 13pt normal control/body text, 12pt metadata. Use the same20-24pt dialog inner inset and a clearly separated header with uniformly sized28-32pt close/control targets. Tabs have a consistent36pt desktop height and12pt section gap. Diagnostic table rows have sufficient6-8pt vertical padding,13pt readable values, aligned label columns and wrap long target paths; modest border grouping no decorative shadows. Empty states are centered within the available content region, with a restrained icon,13pt title and12pt secondary copy, no stretched decorative cards. Export remains an explicit trailing footer action with consistent inset.
New session dialog:17pt heading, plain12pt explanatory copy with comfortable line height,13pt Agent names,12pt secondary commands safely ellipsized, uniform12pt choice-row padding and8pt gaps. Replace floating Material field labels with persistent13pt external label and12pt helper below a30pt field. Existing Cancel and Start remain trailing with consistent8pt gap. Preserve data and current/starting-agent badges; do not add new buttons or remove choices.
No iOS oversized touch controls, no marketing type, no new features, no heavy borders or overly round cards. Accurately readable text. Tiny numbered captions outside each window.


## Chat

Use case: ui-mockup
Asset type: detailed macOS ACP chat/inspector polish specification board.
Input images 1 chat,2 Context panel,3 Session settings,4 Expanded tool output,5 Session menu are all existing screens to refine. Preserve actual product information and functions. Produce ONE high-resolution board with four polished detailed panels: chat with expanded tool output, session settings, session details, and session menu; use the other references to maintain consistent hierarchy.
Keep overall application panes,neutral light palette,blue accent. Use13pt SF Pro interface text,12pt secondary labels,15pt chat reading text and13pt monospaced code, restrained17-20pt dialog titles. Content gets20-24pt dialog inset,12pt field gaps,24pt group separation,aligned label/value columns.
Tool output: preserve input/output selectable code areas but reduce heavy repetitive four-box presentation. Kind and Call ID should be a compact secondary metadata row below Input/Output, neutral separators instead of warning-colored borders for successful tools. Keep real output fully readable.
Session settings: consistent13pt regular dropdown values instead of oversized bold values. Persistent external labels, clear title/description hierarchy, group metadata small and restrained. Consolidate borders so headings don't become empty cards; maintain immediate-apply behavior and Refresh/Done actions.
Session details/overview: add visible top-right Close control and consistent padded heading, matched compact tab control; use13pt regular values and12pt labels,6-8pt vertical row padding, safe long-path wrap. Preserve sections and disclosure behavior. Avoid stacking another modal just to reach details if a direct replacement panel can represent same flow.
Session menu: ordinary13pt regular commands (not all bold), consistent24-30pt row heights, aligned16pt icons and12pt gaps, restrained grouping separators. No new commands. Main composer should use a compact empty state (~110-120pt) while growing for multiline content; preserve all settings/attachments and15pt input text.
No new features or platform migration. No mobile controls,marketing type,decorative cards,large shadows. This is a practical reference for source-code changes, not actual proof of behavior.


## Details

Use case: ui-mockup. Refine the supplied two real ACP macOS session detail screenshots into one 2-panel design reference board. Existing information, structure and blue neutral palette must remain, no new features. Make consistent macOS dialog title 20pt semibold with visible top-right close control,20–24pt dialog content padding, compact tabs with normal13pt type,12pt secondarylabels and13pt readable values,6–8pt row spacing, wrap long paths. Use SF Pro UI and Menlo code. Keep high information density and eliminate redundant heavy borders. Preserve both Context and Workspace overview state information. No mobile layout, decoration, or oversized typography. This is a source implementation reference, not proof of behavior.

