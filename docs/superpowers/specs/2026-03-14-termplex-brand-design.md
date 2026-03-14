# Termplex Brand Design — Electric Cyan

## Overview

Redesign Termplex's visual identity with a cohesive "Electric Cyan" brand. Replace the current inconsistent color soup (6+ unrelated colors) with a unified palette built around a single accent color (#00d4ff) on deep navy backgrounds.

**Problem:** Each UI element was styled independently — the sidebar uses dark navy with hot pink, the header uses the same pink, ports are green, branches are light blue, attention rings are another blue. The sidebar clashes with libadwaita's system theme. There is no cohesive brand.

**Solution:** A disciplined palette with one accent color, four background layers, two semantic colors, and two text shades. Every Termplex CSS class gets updated to use this palette.

## Color Palette

### Backgrounds (4 layers of depth)

| Token | Hex | Usage |
|---|---|---|
| `base` | `#0f1923` | Deepest background, terminal area |
| `sidebar` | `#131d2b` | Sidebar background |
| `surface` | `#1a2736` | Header bar, hover states, elevated surfaces |
| `border` | `#243447` | All borders, dividers, separators |

### Brand Accent

| Token | Hex | Usage |
|---|---|---|
| `primary` | `#00d4ff` | Active indicator, brand text, links, focus rings |
| `primary-muted` | `#00a8cc` | Hover states on primary elements |
| `primary-bg` | `rgba(0, 212, 255, 0.06)` | Active workspace row background |
| `primary-border` | `rgba(0, 212, 255, 0.15)` | Active tab border, subtle glow borders |

### Semantic Colors

| Token | Hex | Usage |
|---|---|---|
| `success` | `#4ade80` | Git branch text, port indicators |
| `danger` | `#f87171` | Delete button, error states |

### Text

| Token | Hex | Usage |
|---|---|---|
| `text-primary` | `#e2e8f0` | Workspace names, active text |
| `text-secondary` | `#7a8ba3` | Inactive workspace names, metadata |

## Component Styles

### Sidebar (`.termplex-sidebar`)

- Background: `sidebar` (#131d2b)
- Border-right: 1px solid `border` (#243447)
- No competing background colors — everything inside the sidebar uses the same base

### Sidebar Header (`.termplex-header`)

- Color: `primary` (#00d4ff)
- Font: bold, letter-spacing: 3px, uppercase
- Padding: 14px 16px
- Border-bottom: 1px solid `border`

### Active Workspace Indicator (`.termplex-sidebar-active`)

- Background: `primary` (#00d4ff)
- Width: 3px, left edge
- Border-radius: 0 2px 2px 0

### Active Workspace Row

- Background: `primary-bg` (rgba(0, 212, 255, 0.06))
- Text color: `text-primary` (#e2e8f0)

### Inactive Workspace Row

- Background: transparent
- Text color: `text-secondary` (#7a8ba3)

### Unread Indicator (`.termplex-sidebar-unread`)

- Background: `primary` (#00d4ff) at 50% opacity
- Same 3px width and border-radius as active

### Git Branch Text (`.termplex-tab-branch`)

- Color: `success` (#4ade80)
- Inactive: `success` at 50% opacity

### Port Text (`.termplex-tab-port`)

- Color: `success` (#4ade80)
- Inactive: `success` at 50% opacity

### Sidebar Toggle (`.termplex-sidebar-toggle`)

- Background: `sidebar` (#131d2b)
- Color: `primary` (#00d4ff)
- Border: 1px solid `border` (#243447)
- Hover: background `surface` (#1a2736)

### New Workspace Button

- Color: `primary` (#00d4ff)
- Border: 1px solid `primary-border`
- Background: transparent
- Hover: background `primary-bg`

### Attention Ring (`.termplex-attention`)

- Border: 2px solid `primary` (#00d4ff)
- Box-shadow: 0 0 12px rgba(0, 212, 255, 0.3)

### Header Bar

- Min-height: 32px (compact)
- Background follows libadwaita system theme (we only override Termplex-specific elements)

### Tab Bar

- Min-height: 28px (compact)
- Active tab: subtle `primary-bg` background with `primary-border`

## Dark Mode Override Strategy

The `style.css` file contains the full brand palette (it's a dark-first design). The `style-dark.css` file only needs to override values that differ from the defaults — in this case, very few overrides are needed since the brand is already dark-native. The dark mode file primarily ensures the sidebar and custom elements use the brand palette rather than inheriting system dark theme colors.

For light mode: the Termplex sidebar and custom elements keep their dark brand colors regardless of system theme. The sidebar is always dark. Only the libadwaita chrome (header bar, tab bar) follows the system theme.

## Files to Modify

1. `src/apprt/gtk/css/style.css` — Update all `.termplex-*` classes with new palette
2. `src/apprt/gtk/css/style-dark.css` — Simplify dark overrides (most values now match base)

## Design Principles

1. **One accent color** — Cyan (#00d4ff) is the only brand color. Everything else is grayscale or semantic.
2. **Layered depth** — Four background shades create depth without heavy borders.
3. **Terminal first** — Chrome fades away. Sidebar, header, tabs are subtle.
4. **Consistent borders** — All borders use #243447. One color, no visual noise.
