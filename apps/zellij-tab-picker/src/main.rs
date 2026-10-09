//! Native tab picker for Zellij.

use std::collections::BTreeMap;
use zellij_tile::prelude::*;

mod logic;
use logic::{
    compute_reduction_tier, pane_count, subsequence_indices, text_width, truncate_to_width,
    viewport_range,
};

#[derive(Default)]
struct TabPicker {
    tabs: Vec<TabInfo>,
    rows: Vec<MatchedTab>,
    query: String,
    selected: Option<usize>,
    style: Styling,
}

struct MatchedTab {
    position: usize,
    tab_id: usize,
    name: String,
    name_indices: Vec<usize>,
    panes: usize,
    full_details: String,
    abbreviated_details: String,
}

impl TabPicker {
    fn rebuild_rows(&mut self, selected_tab_id: Option<usize>) {
        self.rows = self
            .tabs
            .iter()
            .filter(|tab| !tab.active)
            .filter_map(|tab| {
                subsequence_indices(&tab.name, &self.query).map(|name_indices| {
                    let panes = pane_count(
                        tab.selectable_tiled_panes_count,
                        tab.selectable_floating_panes_count,
                        tab.active,
                    );
                    let pane_word = if panes == 1 { "pane" } else { "panes" };
                    MatchedTab {
                        position: tab.position,
                        tab_id: tab.tab_id,
                        name: tab.name.clone(),
                        name_indices,
                        panes,
                        full_details: format!("{panes} {pane_word}"),
                        abbreviated_details: format!("{panes}p"),
                    }
                })
            })
            .collect();
        self.selected = selected_tab_id
            .and_then(|tab_id| self.rows.iter().position(|row| row.tab_id == tab_id));
    }

    fn selected_tab_id(&self) -> Option<usize> {
        self.selected
            .and_then(|selected| self.rows.get(selected))
            .map(|row| row.tab_id)
    }

    fn update_query(&mut self) {
        let selected_tab_id = self.selected_tab_id();
        self.rebuild_rows(selected_tab_id);
    }

    fn move_selection(&mut self, direction: isize) {
        let count = self.rows.len();
        if count == 0 {
            self.selected = None;
        } else {
            self.selected = Some(match (self.selected, direction < 0) {
                (None, true) => count - 1,
                (None, false) => 0,
                (Some(selected), true) => selected.checked_sub(1).unwrap_or(count - 1),
                (Some(selected), false) => (selected + 1) % count,
            });
        }
    }

    fn choose_selected(&self) {
        let selected = self
            .selected
            .and_then(|selected| self.rows.get(selected))
            .or_else(|| {
                if self.query.is_empty() {
                    None
                } else {
                    self.rows.first()
                }
            });
        if let Some(selected) = selected {
            switch_tab_to((selected.position + 1) as u32);
            close_self();
        }
    }

    fn update_tabs(&mut self, tabs: Vec<TabInfo>) {
        let selected_tab_id = self.selected_tab_id();
        self.tabs = tabs;
        self.rebuild_rows(selected_tab_id);
    }

    fn complete_query(&mut self) {
        if let Some(name) = self.rows.first().map(|row| row.name.clone()) {
            self.query = name;
            self.selected = None;
            self.update_query();
        }
    }

    fn handle_key(&mut self, key: KeyWithModifier) -> bool {
        let ctrl_only =
            key.key_modifiers.len() == 1 && key.key_modifiers.contains(&KeyModifier::Ctrl);
        match key.bare_key {
            BareKey::Esc => {
                if self.selected.is_some() {
                    self.selected = None;
                } else {
                    close_self();
                }
            }
            BareKey::Char('c') if ctrl_only => {
                if self.query.is_empty() {
                    close_self();
                } else {
                    self.query.clear();
                    self.selected = None;
                    self.update_query();
                }
            }
            BareKey::Up => self.move_selection(-1),
            BareKey::Down => self.move_selection(1),
            BareKey::Char('k') if ctrl_only => self.move_selection(-1),
            BareKey::Char('j') if ctrl_only => self.move_selection(1),
            BareKey::Tab => self.complete_query(),
            BareKey::Enter => self.choose_selected(),
            BareKey::Backspace => {
                self.query.pop();
                self.selected = None;
                self.update_query();
            }
            BareKey::Char(character)
                if key.key_modifiers.is_empty()
                    || (key.key_modifiers.len() == 1
                        && key.key_modifiers.contains(&KeyModifier::Shift)) =>
            {
                self.query.push(character);
                self.selected = None;
                self.update_query();
            }
            _ => return false,
        }
        true
    }
}

impl ZellijPlugin for TabPicker {
    fn load(&mut self, _configuration: BTreeMap<String, String>) {
        rename_plugin_pane(get_plugin_ids().plugin_id, "Tab Manager");
        subscribe(&[
            EventType::Key,
            EventType::ModeUpdate,
            EventType::PermissionRequestResult,
            EventType::TabUpdate,
        ]);
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::ChangeApplicationState,
        ]);
    }

    fn update(&mut self, event: Event) -> bool {
        match event {
            Event::Key(key) => self.handle_key(key),
            Event::ModeUpdate(mode_info) => {
                self.style = mode_info.style.colors;
                true
            }
            Event::PermissionRequestResult(_) => {
                rename_plugin_pane(get_plugin_ids().plugin_id, "Tab Manager");
                true
            }
            Event::TabUpdate(tabs) => {
                self.update_tabs(tabs);
                true
            }
            _ => false,
        }
    }

    fn render(&mut self, rows: usize, cols: usize) {
        let content_width = cols.min(90);
        let content_x = (cols.saturating_sub(content_width)) / 2;
        let max_table_rows = rows.saturating_sub(5);
        let content_height = 2 + max_table_rows;
        let available_height = rows.saturating_sub(3);
        let content_y = available_height.saturating_sub(content_height) / 2;

        let prompt = color_bold(self.style.exit_code_success.base, "Tab:");
        let query = format!("\u{1b}[1m{}_\u{1b}[22m", self.query);
        let enter_hint = if !self.query.is_empty() && !self.rows.is_empty() {
            let enter = color_bold(self.style.text_unselected.emphasis_3, "<ENTER>");
            format!(" {} - Open", enter)
        } else {
            String::new()
        };
        println!(
            "\u{1b}[m\u{1b}[{};{}H\u{1b}[0m{} {}{}",
            content_y + 2,
            content_x + 1,
            prompt,
            query,
            enter_hint,
        );

        self.render_results(content_x, content_y + 2, content_width, max_table_rows);
        self.render_controls(rows, content_x, content_width);
    }
}

impl TabPicker {
    fn render_results(&self, x: usize, y: usize, max_width: usize, max_rows: usize) {
        if self.rows.is_empty() {
            return;
        }

        let data_rows = max_rows.saturating_sub(1);
        let (start, end) = viewport_range(self.rows.len(), data_rows, self.selected);
        let hidden_above = start;
        let hidden_below = self.rows.len().saturating_sub(end);
        let has_hidden_above = hidden_above > 0;
        let has_hidden_below = hidden_below > 0;
        let has_hidden = has_hidden_above || has_hidden_below;

        let tab_header_full = "<TAB> Complete";
        let tab_header_short = "<TAB>";
        let above_summary_full = format!("[+{hidden_above} Tabs]");
        let above_summary_short = format!("[+{hidden_above}]");
        let below_summary_full = format!("[+{hidden_below} Tabs]");
        let below_summary_short = format!("[+{hidden_below}]");
        let full_summary_width =
            text_width(&above_summary_full).max(text_width(&below_summary_full));
        let short_summary_width =
            text_width(&above_summary_short).max(text_width(&below_summary_short));
        let full_fourth_width =
            text_width(tab_header_full).max(if has_hidden { full_summary_width } else { 1 });
        let short_fourth_width =
            text_width(tab_header_short).max(if has_hidden { short_summary_width } else { 1 });
        let full_name_width = self
            .rows
            .iter()
            .map(|row| text_width(&row.name))
            .max()
            .unwrap_or(0);
        let full_details_width = self
            .rows
            .iter()
            .map(|row| text_width(&row.full_details))
            .max()
            .unwrap_or(0);
        let abbreviated_details_width = self
            .rows
            .iter()
            .map(|row| text_width(&row.abbreviated_details))
            .max()
            .unwrap_or(0);
        let (abbreviate_details, abbreviate_tags, abbreviate_fourth, name_max_width) =
            compute_reduction_tier(
                full_name_width,
                full_details_width,
                text_width("[OPEN]"),
                full_fourth_width,
                abbreviated_details_width,
                short_fourth_width,
                max_width,
            );

        let mut table = Table::new().add_styled_row(vec![
            Text::new(" "),
            Text::new(" "),
            Text::new(" "),
            Text::new(" "),
        ]);
        let visible_count = end.saturating_sub(start);
        for (visible_index, row) in self.rows[start..end].iter().enumerate() {
            let row_index = start + visible_index;
            let display_name = name_max_width
                .map(|max_width| truncate_to_width(&row.name, max_width))
                .unwrap_or_else(|| row.name.clone());
            let display_indices = row
                .name_indices
                .iter()
                .filter(|&&index| index < display_name.chars().count())
                .copied()
                .collect::<Vec<_>>();
            let mut name_cell = Text::new(display_name).color_range(1, ..);
            if !display_indices.is_empty() {
                name_cell = name_cell.color_indices(3, display_indices);
            }

            let details = if abbreviate_details {
                &row.abbreviated_details
            } else {
                &row.full_details
            };
            let details_cell = Text::new(details).color_range(2, 0..row.panes.to_string().len());
            let tag_cell =
                Text::new(if abbreviate_tags { "[O]" } else { "[OPEN]" }).color_range(0, ..);
            let fourth_cell = if visible_index == 0 && has_hidden_above {
                let summary = if abbreviate_fourth {
                    &above_summary_short
                } else {
                    &above_summary_full
                };
                Text::new(summary).color_substring(2, &format!("+{hidden_above}"))
            } else if visible_index == 0 && self.selected.is_none() {
                let hint = if abbreviate_fourth {
                    tab_header_short
                } else {
                    tab_header_full
                };
                Text::new(hint).color_substring(3, "<TAB>")
            } else if visible_index == visible_count.saturating_sub(1) && has_hidden_below {
                let summary = if abbreviate_fourth {
                    &below_summary_short
                } else {
                    &below_summary_full
                };
                Text::new(summary).color_substring(2, &format!("+{hidden_below}"))
            } else {
                Text::new(" ")
            };

            if self.selected == Some(row_index) {
                table = table.add_styled_row(vec![
                    name_cell.selected(),
                    details_cell.selected(),
                    tag_cell.selected(),
                    fourth_cell,
                ]);
            } else {
                table = table.add_styled_row(vec![name_cell, details_cell, tag_cell, fourth_cell]);
            }
        }

        print_table_with_coordinates(table, x, y, Some(max_width), Some(max_rows));
    }

    fn render_controls(&self, rows: usize, x: usize, width: usize) {
        if rows < 2 || width == 0 {
            return;
        }
        let shortcut_color = self.style.text_unselected.emphasis_3;
        let arrows = color_bold(shortcut_color, "<↓↑>");
        let enter = color_bold(shortcut_color, "<ENTER>");
        let tab = color_bold(shortcut_color, "<TAB>");
        let controls = if width > 58 {
            format!(
                "Help: {arrows} - {}, {enter} - {}, {tab} - {}",
                bold("Navigate"),
                bold("Open"),
                bold("Complete"),
            )
        } else if width >= 18 {
            format!("{arrows}/{enter}/{tab}")
        } else {
            String::new()
        };
        if !controls.is_empty() {
            print!(
                "\u{1b}[m\u{1b}[{};{}H{}",
                rows.saturating_sub(1),
                x + 1,
                controls,
            );
        }

        let esc = color_bold(shortcut_color, "<ESC>");
        let tab_word = if self.tabs.len() == 1 { "tab" } else { "tabs" };
        let status = format!("({} {tab_word})", self.tabs.len());
        let full_status_width = 5 + 3 + 5 + 1 + text_width(&status);
        let close_line = if width >= full_status_width {
            format!(
                "{esc} - {} {}",
                bold("Close"),
                color_plain(self.style.exit_code_success.base, &status),
            )
        } else if width >= 5 {
            esc
        } else {
            String::new()
        };
        if !close_line.is_empty() {
            print!("\u{1b}[m\u{1b}[{rows};{}H{close_line}", x + 1);
        }
    }
}

fn bold(text: &str) -> String {
    format!("\u{1b}[1m{text}\u{1b}[22m")
}

fn color_bold(color: PaletteColor, text: &str) -> String {
    match color {
        PaletteColor::EightBit(color) => {
            format!("\u{1b}[38;5;{color};1m{text}\u{1b}[39;22m")
        }
        PaletteColor::Rgb((red, green, blue)) => {
            format!("\u{1b}[38;2;{red};{green};{blue};1m{text}\u{1b}[39;22m")
        }
    }
}

fn color_plain(color: PaletteColor, text: &str) -> String {
    match color {
        PaletteColor::EightBit(color) => format!("\u{1b}[38;5;{color}m{text}\u{1b}[39m"),
        PaletteColor::Rgb((red, green, blue)) => {
            format!("\u{1b}[38;2;{red};{green};{blue}m{text}\u{1b}[39m")
        }
    }
}

register_plugin!(TabPicker);
