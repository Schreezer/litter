//! Typed payloads out of agent prose.
//!
//! Ports the Swift parsers that used to run per render:
//!
//! - `CourseChatQuestion.extract` (`learnfold-question` fences)
//! - `CoursePlanMarkdown.extract` / `parse` (`learnfold-plan` fences)
//! - `CourseExperienceStore.remoteCourseToolCall` and the Hermes
//!   `learnfold_tool_call` / `learnfold_tool_result` envelope checks
//! - `CourseAgentInternalPromptPolicy.isInternalInstruction`,
//!   `CoursePageChatContext.learnerQuestion`,
//!   `CourseChatTimelinePolicy.remoteLearnerMessage` / `selectionQuestion`
//! - `CourseChatTimelinePolicy.projectLiveItems` (course projection)
//!
//! Behaviour matches the Swift code, including hiding a fence that is still
//! open mid-stream. Whitespace trimming follows Foundation's
//! `.whitespaces` / `.whitespacesAndNewlines` character sets.

use std::sync::OnceLock;

use serde_json::Value;

use crate::conversation_uniffi::{
    HydratedConversationItem, HydratedConversationItemContent, HydratedDynamicToolCallData,
    HydratedErrorData, HydratedUserMessageData,
};
use crate::course_assessment::is_course_assessment_discussion_instruction;
use crate::types::AppOperationStatus;

pub const QUESTION_FENCE: &str = "learnfold-question";
pub const PLAN_FENCE: &str = "learnfold-plan";
pub const MINIMUM_QUESTION_OPTIONS: usize = 2;
pub const MAXIMUM_QUESTION_OPTIONS: usize = 5;
pub const DEFAULT_PLAN_DURATION: &str = "Adaptive";

const INTERNAL_INSTRUCTION_MARKER: &str = "<learnfold_internal_course_instruction version=\"1\">";
const REMOTE_PROTOCOL_MARKER: &str = "Learnfold remote native-tool protocol:";
const REMOTE_LEARNER_MARKER: &str = "\n\nLearner message:\n";
const SELECTION_MARKER: &str = "<selected_course_passage";
const SELECTION_QUESTION_MARKER: &str = "\nMy question: ";
const PAGE_CONTEXT_PREFIX: &str =
    "I am reading this course page. Use it as context for my question.\n";
const PAGE_CONTEXT_QUESTION_MARKER: &str = "\n</current_course_page>\n\nMy question: ";
const TOOL_CALL_KEY: &str = "learnfold_tool_call";
const TOOL_RESULT_KEY: &str = "learnfold_tool_result";

pub const COURSE_MCP_SERVER: &str = "learnfold_course";
pub const COURSE_MCP_DIRECT_NAMESPACE: &str = "mcp__learnfold_course";
pub const PRESENT_PLAN_TOOL: &str = "present_course_plan";
pub const COURSE_BASH_TOOL: &str = "course_bash";
/// `NativeEditorMCPToolCatalog` tool names.
pub const EDITOR_TOOLS: [&str; 7] = [
    "native-editor-search",
    "native-editor-fetch",
    "native-editor-create-pages",
    "native-editor-update-page",
    "native-editor-move-pages",
    "native-editor-duplicate-page",
    "native-editor-get-async-task",
];

// ── Foundation character sets ─────────────────────────────────────────────

/// Foundation `CharacterSet.whitespaces`: Unicode `Zs` plus tab.
fn is_space(c: char) -> bool {
    matches!(
        c,
        '\t' | ' '
            | '\u{00A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
    )
}

/// Foundation `CharacterSet.whitespacesAndNewlines`.
fn is_space_or_newline(c: char) -> bool {
    is_space(c) || matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn trim_spaces(text: &str) -> &str {
    text.trim_matches(is_space)
}

fn trim_all(text: &str) -> &str {
    text.trim_matches(is_space_or_newline)
}

/// ASCII case-insensitive substring search without allocating.
fn contains_ignore_ascii_case(haystack: &str, needle: &str) -> bool {
    let needle = needle.as_bytes();
    haystack
        .as_bytes()
        .windows(needle.len())
        .any(|window| window.eq_ignore_ascii_case(needle))
}

fn split_lines(markdown: &str) -> Vec<String> {
    markdown
        .replace("\r\n", "\n")
        .split('\n')
        .map(str::to_string)
        .collect()
}

fn collapse_blank_runs(lines: &[String]) -> String {
    let mut text = lines.join("\n");
    while text.contains("\n\n\n") {
        text = text.replace("\n\n\n", "\n\n");
    }
    trim_all(&text).to_string()
}

fn fence_language(trimmed_line: &str) -> Option<&str> {
    ["```", "~~~"]
        .iter()
        .find_map(|marker| trimmed_line.strip_prefix(marker))
        .map(trim_spaces)
}

fn is_opening_fence(line: &str, language: &str) -> bool {
    fence_language(trim_spaces(line)).is_some_and(|found| found.eq_ignore_ascii_case(language))
}

fn is_closing_fence(line: &str) -> bool {
    let trimmed = trim_spaces(line);
    trimmed == "```" || trimmed == "~~~"
}

/// Ordered-list marker: up to three numerals, then `.` or `)`, then a space.
fn ordered_list_item(trimmed: &str) -> Option<&str> {
    let mut chars = trimmed.char_indices();
    let mut digits = 0;
    let mut separator_at = None;
    for (index, c) in chars.by_ref() {
        if is_number(c) && digits < 3 {
            digits += 1;
            continue;
        }
        separator_at = Some((index, c));
        break;
    }
    let (index, separator) = separator_at?;
    if digits == 0 || !(separator == '.' || separator == ')') {
        return None;
    }
    let rest = &trimmed[index + separator.len_utf8()..];
    rest.starts_with(' ').then(|| trim_spaces(rest))
}

/// Swift's `Character.isNumber`: any character with a Unicode numeric type,
/// which (unlike `char::is_numeric`) includes CJK numeral ideographs.
fn is_number(c: char) -> bool {
    c.is_numeric()
        || matches!(
            c,
            '〇' | '一' | '二' | '三' | '四' | '五' | '六' | '七' | '八' | '九' | '十'
                | '百' | '千' | '万' | '萬' | '億' | '兆' | '零' | '壹' | '贰' | '貳'
                | '叁' | '參' | '肆' | '伍' | '陆' | '陸' | '柒' | '捌' | '玖' | '拾'
                | '佰' | '仟' | '两' | '兩' | '廿' | '卅'
        )
}

fn bullet_item(trimmed: &str) -> Option<&str> {
    ["- ", "* ", "• ", "+ "]
        .iter()
        .find_map(|marker| trimmed.strip_prefix(marker))
        .map(trim_spaces)
}

// ── Questions ─────────────────────────────────────────────────────────────

/// A multiple-choice question the agent asked with a `learnfold-question`
/// fence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuestionPayload {
    /// The question sentence. Empty when the lead-in prose carries it.
    pub prompt: String,
    /// Two to five short, distinct answers in the order the agent wrote them.
    pub options: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuestionExtraction {
    /// The message with every question fence removed and the question
    /// sentence kept as a trailing paragraph.
    pub text: String,
    /// The last complete, valid question in the message.
    pub question: Option<QuestionPayload>,
    /// True while a fence is open but not closed (mid-stream). The partial
    /// block is hidden from `text`.
    pub is_incomplete: bool,
}

pub fn extract_question(markdown: &str) -> QuestionExtraction {
    if !contains_ignore_ascii_case(markdown, QUESTION_FENCE) {
        return QuestionExtraction {
            text: markdown.to_string(),
            question: None,
            is_incomplete: false,
        };
    }
    let lines = split_lines(markdown);
    let mut output: Vec<String> = Vec::new();
    let mut question: Option<QuestionPayload> = None;
    let mut index = 0;
    while index < lines.len() {
        let line = &lines[index];
        if !is_opening_fence(line, QUESTION_FENCE) {
            output.push(line.clone());
            index += 1;
            continue;
        }
        let Some(closing) = lines[index + 1..]
            .iter()
            .position(|line| is_closing_fence(line))
            .map(|offset| index + 1 + offset)
        else {
            // Streaming: hide the block until it closes rather than flashing
            // raw fence text.
            return QuestionExtraction {
                text: cleaned_question_text(&output, question.as_ref().map(|q| q.prompt.as_str())),
                question: None,
                is_incomplete: true,
            };
        };
        let body = &lines[index + 1..closing];
        match parse_question(body) {
            Some(parsed) => question = Some(parsed),
            // Keep malformed content readable as ordinary Markdown.
            None => output.extend(body.iter().cloned()),
        }
        index = closing + 1;
    }
    QuestionExtraction {
        text: cleaned_question_text(&output, question.as_ref().map(|q| q.prompt.as_str())),
        question,
        is_incomplete: false,
    }
}

fn cleaned_question_text(lines: &[String], prompt: Option<&str>) -> String {
    let text = collapse_blank_runs(lines);
    match prompt.filter(|prompt| !prompt.is_empty()) {
        Some(prompt) if text.is_empty() => prompt.to_string(),
        Some(prompt) => format!("{text}\n\n{prompt}"),
        None => text,
    }
}

fn parse_question(body: &[String]) -> Option<QuestionPayload> {
    let joined = body.join("\n");
    let joined = trim_all(&joined);
    if joined.is_empty() {
        return None;
    }
    if joined.starts_with('{') {
        return parse_question_json(joined);
    }
    parse_question_list(body)
}

fn parse_question_json(text: &str) -> Option<QuestionPayload> {
    let Value::Object(object) = serde_json::from_str::<Value>(text).ok()? else {
        return None;
    };
    // Swift: `(object["question"] ?? object["prompt"]) as? String ?? ""`.
    let prompt = object
        .get("question")
        .or_else(|| object.get("prompt"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let options = object.get("options")?.as_array()?;
    let raw_options: Vec<String> = if options.iter().all(Value::is_string) {
        options
            .iter()
            .filter_map(|value| value.as_str().map(str::to_string))
            .collect()
    } else if options.iter().all(Value::is_object) {
        options
            .iter()
            .filter_map(|value| {
                let object = value.as_object()?;
                object
                    .get("label")
                    .or_else(|| object.get("text"))
                    .or_else(|| object.get("title"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .collect()
    } else {
        return None;
    };
    make_question(&prompt, &raw_options)
}

fn parse_question_list(body: &[String]) -> Option<QuestionPayload> {
    let mut prompt_lines: Vec<&str> = Vec::new();
    let mut options: Vec<String> = Vec::new();
    for line in body {
        let trimmed = trim_spaces(line);
        if trimmed.is_empty() {
            continue;
        }
        if let Some(item) = bullet_item(trimmed).or_else(|| ordered_list_item(trimmed)) {
            options.push(item.to_string());
        } else if options.is_empty() {
            prompt_lines.push(trimmed);
        }
        // Prose after the options is dropped.
    }
    make_question(&prompt_lines.join(" "), &options)
}

fn make_question(prompt: &str, raw_options: &[String]) -> Option<QuestionPayload> {
    let mut seen = std::collections::HashSet::new();
    let mut options = Vec::new();
    for option in raw_options {
        let trimmed = trim_all(option).trim_matches(|c| c == '"' || c == '\'');
        if trimmed.is_empty() || !seen.insert(trimmed.to_lowercase()) {
            continue;
        }
        options.push(trimmed.to_string());
        if options.len() == MAXIMUM_QUESTION_OPTIONS {
            break;
        }
    }
    (options.len() >= MINIMUM_QUESTION_OPTIONS).then(|| QuestionPayload {
        prompt: trim_all(prompt).to_string(),
        options,
    })
}

// ── Plans ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, uniffi::Enum)]
pub enum ChatPlanNodeRole {
    Explainer,
    Module,
    Lesson,
    Subchapter,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanNode {
    pub title: String,
    pub role: Option<ChatPlanNodeRole>,
    pub children: Vec<PlanNode>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanChapter {
    pub title: String,
    pub objective: String,
    pub children: Vec<PlanNode>,
}

/// A course plan written in a `learnfold-plan` fence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanMarkdown {
    pub title: String,
    pub summary: String,
    pub outcome: String,
    pub starting_point: String,
    pub focus_gap: String,
    pub estimated_duration: String,
    pub chapters: Vec<PlanChapter>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlanBlock {
    Plan(PlanMarkdown),
    Invalid(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanExtraction {
    /// The message with every plan fence removed.
    pub text: String,
    pub blocks: Vec<PlanBlock>,
    /// True while a plan fence is open but not yet closed (mid-stream).
    pub is_incomplete: bool,
}

pub fn contains_plan_fence(markdown: &str) -> bool {
    contains_ignore_ascii_case(markdown, PLAN_FENCE)
}

pub fn extract_plan(markdown: &str) -> PlanExtraction {
    if !contains_plan_fence(markdown) {
        return PlanExtraction {
            text: markdown.to_string(),
            blocks: Vec::new(),
            is_incomplete: false,
        };
    }
    let lines = split_lines(markdown);
    let mut output: Vec<String> = Vec::new();
    let mut blocks = Vec::new();
    let mut index = 0;
    while index < lines.len() {
        let line = &lines[index];
        if !is_opening_fence(line, PLAN_FENCE) {
            output.push(line.clone());
            index += 1;
            continue;
        }
        let Some(closing) = lines[index + 1..]
            .iter()
            .position(|line| is_closing_fence(line))
            .map(|offset| index + 1 + offset)
        else {
            return PlanExtraction {
                text: collapse_blank_runs(&output),
                blocks,
                is_incomplete: true,
            };
        };
        blocks.push(match parse_plan(&lines[index + 1..closing]) {
            Ok(plan) => PlanBlock::Plan(plan),
            Err(issue) => PlanBlock::Invalid(issue),
        });
        index = closing + 1;
    }
    PlanExtraction {
        text: collapse_blank_runs(&output),
        blocks,
        is_incomplete: false,
    }
}

pub fn parse_plan(body: &[String]) -> Result<PlanMarkdown, String> {
    let mut title = String::new();
    let mut fields: std::collections::HashMap<&'static str, String> =
        std::collections::HashMap::new();
    let mut chapters: Vec<PlanChapter> = Vec::new();
    // Bullet stack for the current chapter: (indent, path of child indexes).
    let mut stack: Vec<(i64, Vec<usize>)> = Vec::new();
    let mut subchapter_indent: Option<i64> = None;

    fn nodes_at<'a>(chapters: &'a mut [PlanChapter], path: &[usize]) -> Option<&'a mut Vec<PlanNode>> {
        let chapter = chapters.last_mut()?;
        let mut nodes = &mut chapter.children;
        for index in path {
            nodes = &mut nodes.get_mut(*index)?.children;
        }
        Some(nodes)
    }

    for raw_line in body {
        let expanded = raw_line.replace('\t', "    ");
        let trimmed = trim_spaces(&expanded);
        if trimmed.is_empty() {
            continue;
        }
        let indent = expanded.chars().take_while(|c| *c == ' ').count() as i64;

        if let Some((level, text)) = plan_heading(trimmed) {
            let text = clean_title(text);
            match level {
                1 => {
                    if title.is_empty() {
                        title = text;
                    }
                }
                2 => {
                    chapters.push(PlanChapter {
                        title: text,
                        objective: String::new(),
                        children: Vec::new(),
                    });
                    stack.clear();
                    subchapter_indent = None;
                }
                _ => {
                    if chapters.is_empty() {
                        continue;
                    }
                    let (node_title, _) = title_and_role(&text);
                    let Some(nodes) = nodes_at(&mut chapters, &[]) else {
                        continue;
                    };
                    nodes.push(PlanNode {
                        title: node_title,
                        role: Some(ChatPlanNodeRole::Subchapter),
                        children: Vec::new(),
                    });
                    stack = vec![(-1, vec![nodes.len() - 1])];
                    subchapter_indent = Some(-1);
                }
            }
            continue;
        }

        if let Some(item) = plan_list_item(trimmed) {
            if chapters.is_empty() {
                continue;
            }
            while let Some((last_indent, _)) = stack.last() {
                if *last_indent >= indent && Some(*last_indent) != subchapter_indent {
                    stack.pop();
                } else {
                    break;
                }
            }
            let parent_path = stack.last().map(|(_, path)| path.clone()).unwrap_or_default();
            let (node_title, role) = title_and_role(&clean_title(item));
            let Some(nodes) = nodes_at(&mut chapters, &parent_path) else {
                continue;
            };
            nodes.push(PlanNode {
                title: node_title,
                role,
                children: Vec::new(),
            });
            let mut path = parent_path;
            path.push(nodes.len() - 1);
            stack.push((indent, path));
            continue;
        }

        if let Some((key, value)) = plan_key_value(trimmed) {
            if chapters.is_empty() {
                if key == "title" {
                    if title.is_empty() {
                        title = clean_title(&value);
                    }
                } else {
                    fields.entry(key).or_insert(value);
                }
            } else if key == "objective"
                && let Some(chapter) = chapters.last_mut()
                && chapter.objective.is_empty()
            {
                chapter.objective = value;
            }
            continue;
        }

        // A plain prose line directly under a chapter heading reads as its
        // objective when the agent omitted the label.
        if let Some(chapter) = chapters.last_mut()
            && chapter.objective.is_empty()
            && chapter.children.is_empty()
        {
            chapter.objective = trimmed.to_string();
        }
    }

    let mut missing: Vec<&str> = Vec::new();
    if title.is_empty() {
        missing.push("a `# Title` line");
    }
    for (key, label) in [
        ("summary", "`Summary:`"),
        ("outcome", "`Outcome:`"),
        ("starting_point", "`Starting point:`"),
        ("focus_gap", "`Focus:`"),
    ] {
        if fields.get(key).is_none_or(|value| value.is_empty()) {
            missing.push(label);
        }
    }
    if chapters.is_empty() {
        missing.push("at least one `## Chapter` heading");
    }
    if !missing.is_empty() {
        return Err(format!("The plan is missing {}.", missing.join(", ")));
    }
    let field = |key: &str| fields.get(key).cloned().unwrap_or_default();
    Ok(PlanMarkdown {
        title,
        summary: field("summary"),
        outcome: field("outcome"),
        starting_point: field("starting_point"),
        focus_gap: field("focus_gap"),
        estimated_duration: fields
            .get("estimated_duration")
            .cloned()
            .unwrap_or_else(|| DEFAULT_PLAN_DURATION.to_string()),
        chapters,
    })
}

fn plan_heading(trimmed: &str) -> Option<(usize, &str)> {
    let hashes = trimmed.chars().take_while(|c| *c == '#').count();
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let rest = &trimmed[hashes..];
    if !rest.starts_with(' ') {
        return None;
    }
    let text = trim_spaces(rest);
    (!text.is_empty()).then_some((hashes, text))
}

fn plan_list_item(trimmed: &str) -> Option<&str> {
    bullet_item(trimmed)
        .or_else(|| ordered_list_item(trimmed))
        .filter(|text| !text.is_empty())
}

fn plan_field_alias(raw_key: &str) -> Option<&'static str> {
    Some(match raw_key {
        "title" | "course title" => "title",
        "summary" => "summary",
        "outcome" | "outcomes" | "goal" => "outcome",
        "starting point" | "starting_point" | "start" => "starting_point",
        "focus" | "focus gap" | "focus_gap" | "gap" => "focus_gap",
        "duration" | "estimated duration" | "estimated_duration" => "estimated_duration",
        "objective" | "goal of chapter" => "objective",
        _ => return None,
    })
}

fn plan_key_value(trimmed: &str) -> Option<(&'static str, String)> {
    let unbolded = trimmed.replace("**", "").replace("__", "");
    let colon = unbolded.find(':')?;
    let raw_key = trim_spaces(&unbolded[..colon]).to_lowercase();
    let key = plan_field_alias(&raw_key)?;
    let value = trim_spaces(&unbolded[colon + 1..]).to_string();
    (!value.is_empty()).then_some((key, value))
}

fn title_prefix_patterns() -> &'static [regex::Regex; 3] {
    static PATTERNS: OnceLock<[regex::Regex; 3]> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        [
            regex::Regex::new(
                r"^(?i:(?:chapter|part|unit|section|lesson|module)\s+\d+(?:\.\d+)*)\s*[.):\-–—]?\s*",
            )
            .expect("valid title prefix regex"),
            regex::Regex::new(r"^\d{1,2}(?:\.\d{1,2})+\.?\s+").expect("valid numbering regex"),
            regex::Regex::new(r"^\d{1,2}[.)]\s+").expect("valid ordinal regex"),
        ]
    })
}

/// Strips Markdown emphasis and ordinal prefixes such as "Chapter 2:",
/// "1.3", or "Lesson 4 -" so titles match the native pages.
fn clean_title(raw: &str) -> String {
    let unmarked = raw.replace("**", "").replace("__", "").replace('`', "");
    let mut text = trim_spaces(&unmarked).to_string();
    for pattern in title_prefix_patterns() {
        if let Some(found) = pattern.find(&text)
            && found.end() < text.len()
        {
            text = text[found.end()..].to_string();
            break;
        }
    }
    trim_spaces(&text).to_string()
}

fn title_and_role(text: &str) -> (String, Option<ChatPlanNodeRole>) {
    let roles = [
        ("explainer", ChatPlanNodeRole::Explainer),
        ("module", ChatPlanNodeRole::Module),
        ("lesson", ChatPlanNodeRole::Lesson),
    ];
    let lowered = text.to_lowercase();
    let char_count = text.chars().count();
    for (name, role) in roles {
        for suffix in [format!(" ({name})"), format!(" [{name}]")] {
            if lowered.ends_with(&suffix) {
                let keep = char_count.saturating_sub(suffix.chars().count());
                let kept: String = text.chars().take(keep).collect();
                return (trim_spaces(&kept).to_string(), Some(role));
            }
        }
        let label = format!("{name}:");
        if lowered.starts_with(&label) && char_count > label.chars().count() {
            let rest: String = text.chars().skip(label.chars().count()).collect();
            return (trim_spaces(&rest).to_string(), Some(role));
        }
    }
    (text.to_string(), None)
}

// ── Hermes native-tool envelopes ──────────────────────────────────────────

/// A `{"learnfold_tool_call":{"name":…,"arguments":{…}}}` envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteToolCall {
    pub name: String,
    /// Arguments re-serialized with sorted keys.
    pub arguments_json: String,
}

/// A `{"learnfold_tool_result":{…}}` envelope the device sent back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteToolResult {
    pub call_id: Option<String>,
    pub name: Option<String>,
    pub success: Option<bool>,
}

pub fn is_editor_tool(name: &str) -> bool {
    EDITOR_TOOLS.contains(&name)
}

pub fn is_course_tool(name: &str) -> bool {
    name == PRESENT_PLAN_TOOL || name == COURSE_BASH_TOOL || is_editor_tool(name)
}

/// Serializes JSON like Darwin's `JSONSerialization(.sortedKeys)`, so
/// argument JSON matches what the Swift tool runner journaled: keys sorted,
/// `/` escaped as `\/`, and whole-number doubles written without a
/// fraction (`1.0` → `1`).
pub fn canonical_json(value: &Value) -> String {
    fn write(value: &Value, out: &mut String) {
        match value {
            Value::Object(map) => {
                let mut keys: Vec<&String> = map.keys().collect();
                keys.sort();
                out.push('{');
                for (index, key) in keys.into_iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    write_string(key, out);
                    out.push(':');
                    write(&map[key], out);
                }
                out.push('}');
            }
            Value::Array(values) => {
                out.push('[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    write(value, out);
                }
                out.push(']');
            }
            Value::String(text) => write_string(text, out),
            Value::Number(number) => match number.as_f64() {
                Some(float)
                    if !number.is_i64()
                        && !number.is_u64()
                        && float.fract() == 0.0
                        && float.abs() < 1e15 =>
                {
                    out.push_str(&format!("{}", float as i64));
                }
                _ => out.push_str(&number.to_string()),
            },
            other => out.push_str(&other.to_string()),
        }
    }
    fn write_string(text: &str, out: &mut String) {
        let encoded = Value::String(text.to_string()).to_string();
        out.push_str(&encoded.replace('/', "\\/"));
    }
    let mut out = String::new();
    write(value, &mut out);
    out
}

/// Port of `CourseExperienceStore.remoteCourseToolCall(from:)`: exactly one
/// bare, allowlisted envelope and nothing else.
pub fn remote_tool_call(response: &str) -> Option<RemoteToolCall> {
    let envelope = trim_all(response);
    if !envelope.starts_with('{') || !envelope.ends_with('}') {
        return None;
    }
    let Value::Object(root) = serde_json::from_str::<Value>(envelope).ok()? else {
        return None;
    };
    if root.len() != 1 {
        return None;
    }
    let call = root.get(TOOL_CALL_KEY)?.as_object()?;
    if call.len() != 2 {
        return None;
    }
    let name = call.get("name")?.as_str()?;
    if trim_all(name).is_empty() || !is_course_tool(name) {
        return None;
    }
    let arguments = call.get("arguments")?;
    if !arguments.is_object() {
        return None;
    }
    Some(RemoteToolCall {
        name: name.to_string(),
        arguments_json: canonical_json(arguments),
    })
}

/// Port of the timeline's `isRemoteCourseToolEnvelope`.
pub fn is_tool_call_envelope(text: &str) -> bool {
    let trimmed = trim_all(text);
    trimmed.starts_with('{') && trimmed.contains("\"learnfold_tool_call\"")
}

/// Streaming guard: text that is still becoming a tool envelope (for
/// example `{"learnf`). Hidden so raw JSON never flashes.
pub fn is_partial_tool_call_envelope(text: &str) -> bool {
    let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    if compact.is_empty() || !compact.starts_with('{') {
        return false;
    }
    let key = "{\"learnfold_tool_call\"";
    key.starts_with(&compact) || compact.starts_with(key)
}

/// Port of the timeline's `isRemoteCourseToolResultEnvelope`.
pub fn is_tool_result_envelope(text: &str) -> bool {
    let trimmed = trim_all(text);
    trimmed.starts_with('{') && trimmed.contains("\"learnfold_tool_result\"")
}

/// Reads a result envelope. The device wrote it as JSON followed by a
/// continuation paragraph, so only the first line is parsed.
pub fn remote_tool_result(text: &str) -> Option<RemoteToolResult> {
    let trimmed = trim_all(text);
    if !is_tool_result_envelope(trimmed) {
        return None;
    }
    let json = trimmed.split("\n\n").next().unwrap_or(trimmed);
    let value = serde_json::from_str::<Value>(trim_all(json)).ok()?;
    let result = value.get(TOOL_RESULT_KEY)?.as_object()?;
    Some(RemoteToolResult {
        call_id: result.get("call_id").and_then(Value::as_str).map(str::to_string),
        name: result.get("name").and_then(Value::as_str).map(str::to_string),
        success: result.get("success").and_then(Value::as_bool),
    })
}

// ── Internal prompt markers ───────────────────────────────────────────────

/// Port of `CourseAgentInternalPromptPolicy.isInternalInstruction`.
pub fn is_internal_instruction(text: &str) -> bool {
    let lowercased = trim_all(text).to_lowercase();
    if lowercased.contains(INTERNAL_INSTRUCTION_MARKER) {
        return true;
    }
    // Prompts emitted by older Learnfold builds. Several product-only phrases
    // must all appear so a learner merely naming a tool is never hidden.
    let legacy_targeted_generation = lowercased
        .contains("this request was started from the learn screen")
        && lowercased.contains("native-editor-fetch")
        && lowercased.contains("native-editor-update-page")
        && lowercased.contains("pending_generation")
        && lowercased.contains("never generate siblings or later sections");
    if legacy_targeted_generation {
        return true;
    }
    lowercased.starts_with("i approve course plan ")
        && lowercased.contains("learnfold has already created")
        && (lowercased.contains("learnfold_generate_lesson")
            || lowercased.contains("generation_status"))
        && lowercased.contains("do not recreate the course structure")
}

/// Port of `CoursePageChatContext.learnerQuestion(from:)`.
pub fn page_context_question(prompt: &str) -> Option<String> {
    if !prompt.starts_with(PAGE_CONTEXT_PREFIX) {
        return None;
    }
    let start = prompt.find(PAGE_CONTEXT_QUESTION_MARKER)? + PAGE_CONTEXT_QUESTION_MARKER.len();
    Some(prompt[start..].to_string())
}

/// Port of `CourseChatTimelinePolicy.selectionQuestion(from:)`.
pub fn selection_question(prompt: &str) -> Option<String> {
    if !prompt.contains(SELECTION_MARKER) {
        return None;
    }
    let start = prompt.find(SELECTION_QUESTION_MARKER)? + SELECTION_QUESTION_MARKER.len();
    let question = trim_all(&prompt[start..]);
    (!question.is_empty()).then(|| question.to_string())
}

/// Port of `CourseChatTimelinePolicy.remoteLearnerMessage(from:)`.
pub fn remote_learner_message(prompt: &str) -> Option<String> {
    if !prompt.contains(REMOTE_PROTOCOL_MARKER) {
        return None;
    }
    let start = prompt.find(REMOTE_LEARNER_MARKER)? + REMOTE_LEARNER_MARKER.len();
    let message = trim_all(&prompt[start..]);
    (!message.is_empty()).then(|| message.to_string())
}

/// The learner-visible text of a user message, or `None` when the whole
/// message is internal and must be hidden.
pub fn learner_visible_text(text: &str, hides_selection_envelope: bool) -> Option<String> {
    if is_tool_result_envelope(text) {
        return None;
    }
    let projected = if let Some(message) = remote_learner_message(text) {
        Some(page_context_question(&message).unwrap_or(message))
    } else if let Some(question) = page_context_question(text) {
        Some(question)
    } else if hides_selection_envelope {
        selection_question(text)
    } else {
        None
    };
    let learner_text = projected.as_deref().unwrap_or(text);
    if is_course_assessment_discussion_instruction(learner_text.to_string())
        || is_internal_instruction(learner_text)
    {
        return None;
    }
    Some(projected.unwrap_or_else(|| text.to_string()))
}

// ── Assistant text ────────────────────────────────────────────────────────

/// Everything the chat needs from one assistant message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedAssistant {
    /// Learner-visible Markdown: fences removed, question sentence kept.
    pub display_text: String,
    pub question: Option<QuestionPayload>,
    pub plans: Vec<PlanBlock>,
    /// A plan fence is still open (mid-stream).
    pub plan_streaming: bool,
    /// A question fence is still open (mid-stream).
    pub question_streaming: bool,
}

/// Port of `CourseChatQuestionPolicy.strippingQuestions` plus plan
/// extraction: plan fences first, then question fences on what remains.
pub fn normalize_assistant_text(text: &str) -> NormalizedAssistant {
    let plan = extract_plan(text);
    let question = extract_question(&plan.text);
    NormalizedAssistant {
        display_text: question.text,
        question: question.question,
        plans: plan.blocks,
        plan_streaming: plan.is_incomplete,
        question_streaming: question.is_incomplete,
    }
}

/// As [`normalize_assistant_text`], and while the message is still
/// streaming also hides a trailing line that is becoming a Learnfold fence
/// opener (for example a bare "```" or "```learnf"), which the Swift parser
/// briefly showed as raw text.
pub fn normalize_streaming_assistant_text(text: &str, is_streaming: bool) -> NormalizedAssistant {
    if !is_streaming {
        return normalize_assistant_text(text);
    }
    let (head, last_line) = match text.rfind('\n') {
        Some(index) => (&text[..index], &text[index + 1..]),
        None => ("", text),
    };
    if !is_partial_fence_opener(last_line) {
        return normalize_assistant_text(text);
    }
    let mut normalized = normalize_assistant_text(head);
    // Inside an open Learnfold fence a bare "```" is its closer, not a new
    // opener: parse the full text so the closed block shows at once.
    if (normalized.plan_streaming || normalized.question_streaming)
        && is_closing_fence(last_line)
    {
        return normalize_assistant_text(text);
    }
    normalized.display_text = trim_all(&normalized.display_text).to_string();
    normalized
}

fn is_partial_fence_opener(line: &str) -> bool {
    let trimmed = trim_spaces(line);
    // A lone backtick run shorter than a fence may still become one.
    if !trimmed.is_empty() && trimmed.len() < 3 && trimmed.chars().all(|c| c == '`' || c == '~') {
        return true;
    }
    let Some(language) = fence_language(trimmed) else {
        return false;
    };
    let language = language.to_ascii_lowercase();
    [QUESTION_FENCE, PLAN_FENCE]
        .iter()
        .any(|fence| fence.starts_with(language.as_str()))
}

// ── Course projection (`projectLiveItems`) ────────────────────────────────

pub(crate) fn is_internal_course_server(server: &str) -> bool {
    server == COURSE_MCP_SERVER || server == COURSE_MCP_DIRECT_NAMESPACE
}

/// A course tool name without the direct `mcp__learnfold_course__` prefix.
pub(crate) fn course_tool_name(tool: &str) -> &str {
    tool.strip_prefix(COURSE_MCP_DIRECT_NAMESPACE)
        .and_then(|rest| rest.strip_prefix("__"))
        .unwrap_or(tool)
}

pub(crate) fn is_internal_course_dynamic_tool(data: &HydratedDynamicToolCallData) -> bool {
    if data.tool == PRESENT_PLAN_TOOL || is_editor_tool(&data.tool) {
        return true;
    }
    if let Some(namespace) = data.namespace.as_deref()
        && is_internal_course_server(namespace)
    {
        return true;
    }
    data.tool
        .starts_with(&format!("{COURSE_MCP_DIRECT_NAMESPACE}__"))
}

/// Course tools the learner never sees as work: plan presentation and
/// native-editor calls (Swift's internal dynamic tools).
fn is_course_tool_hidden_from_learner(tool: &str) -> bool {
    tool == PRESENT_PLAN_TOOL || is_editor_tool(tool)
}

fn is_internal_course_action_user_item(item: &HydratedConversationItem) -> bool {
    let HydratedConversationItemContent::User(data) = &item.content else {
        return false;
    };
    let learner_text = remote_learner_message(&data.text).unwrap_or_else(|| data.text.clone());
    // Assessment controls contain quoted lesson data. A quoted generation marker
    // must not turn their assistant-initiated discussion into a hidden course action.
    !is_course_assessment_discussion_instruction(learner_text.clone())
        && is_internal_instruction(&learner_text)
}

fn is_assessment_discussion_user_item(item: &HydratedConversationItem) -> bool {
    let HydratedConversationItemContent::User(data) = &item.content else {
        return false;
    };
    let learner_text = remote_learner_message(&data.text).unwrap_or_else(|| data.text.clone());
    is_course_assessment_discussion_instruction(learner_text)
}

fn course_action_failure(item: &HydratedConversationItem, tool: &str) -> HydratedConversationItem {
    let message = if tool == PRESENT_PLAN_TOOL {
        "The course plan couldn’t be prepared. Please try again."
    } else {
        "The course couldn’t be updated. Please try again."
    };
    HydratedConversationItem {
        content: HydratedConversationItemContent::Error(HydratedErrorData {
            title: "Course action failed".to_string(),
            message: message.to_string(),
            details: None,
        }),
        ..item.clone()
    }
}

/// `namespace` of tool items typed from Hermes envelopes. Course projection
/// hides them like Swift hid the envelopes, failures included (Swift sent a
/// failed result back to Hermes and surfaced nothing in the timeline).
pub const HERMES_ENVELOPE_NAMESPACE: &str = "learnfold_hermes_envelope";

/// Converts Hermes text envelopes into typed tool items, matching Swift's
/// timeline, which hid every envelope:
///
/// - a complete, valid `learnfold_tool_call` assistant message becomes a
///   dynamic tool call (a work entry when course activity is shown);
/// - a half-streamed, malformed, or prose-trailed envelope is hidden;
/// - the device's `learnfold_tool_result` reply completes the call and is
///   hidden.
///
/// `streaming_item_id` names the assistant item still being written, whose
/// partial envelope must not flash as prose.
pub fn type_hermes_envelopes(
    items: Vec<HydratedConversationItem>,
    streaming_item_id: Option<&str>,
) -> Vec<HydratedConversationItem> {
    let mut out: Vec<HydratedConversationItem> = Vec::with_capacity(items.len());
    // Index (in `out`) of the latest envelope tool still awaiting a result.
    let mut open_call: Option<usize> = None;
    for item in items {
        match &item.content {
            HydratedConversationItemContent::Assistant(data) => {
                let streaming = streaming_item_id == Some(item.id.as_str());
                if streaming && is_partial_tool_call_envelope(&data.text) {
                    continue;
                }
                if !is_tool_call_envelope(&data.text) {
                    out.push(item);
                    continue;
                }
                let Some(call) = remote_tool_call(&data.text) else {
                    continue;
                };
                open_call = Some(out.len());
                out.push(HydratedConversationItem {
                    content: HydratedConversationItemContent::DynamicToolCall(
                        HydratedDynamicToolCallData {
                            namespace: Some(HERMES_ENVELOPE_NAMESPACE.to_string()),
                            tool: call.name,
                            status: AppOperationStatus::InProgress,
                            duration_ms: None,
                            success: None,
                            arguments_json: Some(call.arguments_json),
                            content_summary: None,
                            display: None,
                        },
                    ),
                    ..item
                });
            }
            HydratedConversationItemContent::User(data) if is_tool_result_envelope(&data.text) => {
                let result = remote_tool_result(&data.text);
                if let Some(index) = open_call.take()
                    && let HydratedConversationItemContent::DynamicToolCall(call) =
                        &mut out[index].content
                {
                    let success = result.as_ref().and_then(|result| result.success).unwrap_or(true);
                    call.status = if success {
                        AppOperationStatus::Completed
                    } else {
                        AppOperationStatus::Failed
                    };
                    call.success = Some(success);
                }
                // The result envelope itself is never learner-visible.
            }
            _ => out.push(item),
        }
    }
    out
}

/// Port of `CourseChatTimelinePolicy.projectLiveItems`: hides internal course
/// turns and internal course tools (surfacing their failures), and projects
/// learner text out of Learnfold's prompt wrappers. Assessment discussion
/// controls hide only their user item; the assistant's opening question remains visible.
pub fn project_course_items(
    items: Vec<HydratedConversationItem>,
    hides_selection_envelope: bool,
) -> Vec<HydratedConversationItem> {
    let internal_turn_ids: std::collections::HashSet<String> = items
        .iter()
        .filter(|item| is_internal_course_action_user_item(item))
        .filter_map(|item| item.source_turn_id.clone())
        .collect();
    let internal_turn_indices: std::collections::HashSet<u32> = items
        .iter()
        .filter(|item| is_internal_course_action_user_item(item))
        .filter_map(|item| item.source_turn_index)
        .collect();
    let mut suppresses_unscoped_internal_turn = false;
    let mut projected = Vec::with_capacity(items.len());
    for item in items {
        if is_assessment_discussion_user_item(&item) {
            // This control starts a teaching conversation, rather than a course
            // generation action. Reset legacy unscoped suppression so its first
            // assistant question survives both live and restored projections.
            suppresses_unscoped_internal_turn = false;
            continue;
        }
        if is_internal_course_action_user_item(&item) {
            // Treat every internal learner instruction as a whole-turn
            // boundary until the next genuine learner message.
            suppresses_unscoped_internal_turn = true;
            continue;
        }
        if item
            .source_turn_id
            .as_ref()
            .is_some_and(|id| internal_turn_ids.contains(id))
            || item
                .source_turn_index
                .is_some_and(|index| internal_turn_indices.contains(&index))
        {
            continue;
        }
        if suppresses_unscoped_internal_turn {
            match &item.content {
                HydratedConversationItemContent::User(data)
                    if !is_tool_result_envelope(&data.text) =>
                {
                    suppresses_unscoped_internal_turn = false;
                }
                _ => continue,
            }
        }
        if let Some(item) = project_course_item(item, hides_selection_envelope) {
            projected.push(item);
        }
    }
    projected
}

fn project_course_item(
    item: HydratedConversationItem,
    hides_selection_envelope: bool,
) -> Option<HydratedConversationItem> {
    match &item.content {
        HydratedConversationItemContent::McpToolCall(data) if is_internal_course_server(&data.server) => {
            (data.status == AppOperationStatus::Failed).then(|| course_action_failure(&item, &data.tool))
        }
        HydratedConversationItemContent::DynamicToolCall(data)
            if data.namespace.as_deref() == Some(HERMES_ENVELOPE_NAMESPACE)
                && is_course_tool_hidden_from_learner(&data.tool) =>
        {
            None
        }
        HydratedConversationItemContent::DynamicToolCall(data)
            if is_internal_course_dynamic_tool(data) =>
        {
            (data.status == AppOperationStatus::Failed).then(|| course_action_failure(&item, &data.tool))
        }
        HydratedConversationItemContent::Assistant(data) if is_tool_call_envelope(&data.text) => None,
        HydratedConversationItemContent::User(data) => {
            let text = learner_visible_text(&data.text, hides_selection_envelope)?;
            if text == data.text {
                return Some(item);
            }
            Some(HydratedConversationItem {
                content: HydratedConversationItemContent::User(HydratedUserMessageData {
                    text,
                    image_data_uris: data.image_data_uris.clone(),
                }),
                ..item
            })
        }
        _ => Some(item),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BLOCK: &str = "```learnfold-question\nWhat experience do you already have with cryptography?\n- New to cryptography and blockchain\n- I understand basic cryptography\n- I've built blockchain or smart-contract applications\n- I've studied zero-knowledge proofs\n```";

    // ── CourseChatQuestionTests ──

    #[test]
    fn extracts_list_block_and_keeps_question_sentence_in_text() {
        let extraction = extract_question(&format!("Great topic. Let's tailor it.\n\n{BLOCK}"));
        let question = extraction.question.clone().expect("question");
        assert_eq!(question.prompt, "What experience do you already have with cryptography?");
        assert_eq!(
            question.options,
            vec![
                "New to cryptography and blockchain",
                "I understand basic cryptography",
                "I've built blockchain or smart-contract applications",
                "I've studied zero-knowledge proofs",
            ]
        );
        assert_eq!(
            extraction.text,
            "Great topic. Let's tailor it.\n\nWhat experience do you already have with cryptography?"
        );
        assert!(!extraction.text.contains("```"));
        assert!(!extraction.is_incomplete);
    }

    #[test]
    fn leaves_messages_without_a_fence_untouched() {
        let text = "Plain reply with a ```swift\nlet x = 1\n``` code block.";
        let extraction = extract_question(text);
        assert_eq!(extraction.text, text);
        assert_eq!(extraction.question, None);
    }

    #[test]
    fn accepts_json_numbered_and_tilde_variants() {
        let json = "```learnfold-question\n{\"question\": \"How deep?\", \"options\": [\"Overview\", \"Hands-on\", \"Research level\"]}\n```";
        assert_eq!(
            extract_question(json).question,
            Some(QuestionPayload {
                prompt: "How deep?".into(),
                options: vec!["Overview".into(), "Hands-on".into(), "Research level".into()],
            })
        );
        let numbered = "~~~ Learnfold-Question\nPace?\n1. Slow\n2) Fast\n~~~";
        assert_eq!(
            extract_question(numbered).question,
            Some(QuestionPayload {
                prompt: "Pace?".into(),
                options: vec!["Slow".into(), "Fast".into()],
            })
        );
        let objects = "```learnfold-question\n{\"prompt\": \"Goal?\", \"options\": [{\"label\": \"Ship\"}, {\"text\": \"Learn\"}]}\n```";
        assert_eq!(
            extract_question(objects).question.map(|q| q.options),
            Some(vec!["Ship".to_string(), "Learn".to_string()])
        );
    }

    #[test]
    fn hides_an_unclosed_fence_while_streaming() {
        let streaming = "Quick check first.\n\n```learnfold-question\nWhat do you know?\n- Nothing\n- A bit";
        let extraction = extract_question(streaming);
        assert_eq!(extraction.text, "Quick check first.");
        assert_eq!(extraction.question, None);
        assert!(extraction.is_incomplete);
    }

    #[test]
    fn unwraps_blocks_with_too_few_options_as_plain_text() {
        let extraction = extract_question("Intro.\n\n```learnfold-question\nReady?\n- Yes\n```");
        assert_eq!(extraction.question, None);
        assert_eq!(extraction.text, "Intro.\n\nReady?\n- Yes");
    }

    #[test]
    fn caps_dedupes_and_trims_options() {
        let block = "```learnfold-question\nWhich?\n- \"A\"\n-  a\n- B\n- C\n- D\n- E\n- F\n```";
        assert_eq!(
            extract_question(block).question.map(|q| q.options),
            Some(vec!["A", "B", "C", "D", "E"].into_iter().map(String::from).collect())
        );
    }

    #[test]
    fn last_complete_block_wins_and_every_fence_is_removed() {
        let first = "```learnfold-question\nFirst?\n- 1\n- 2\n```";
        let second = "```learnfold-question\nSecond?\n- 3\n- 4\n```";
        let extraction = extract_question(&format!("{first}\n\nBetween.\n\n{second}"));
        assert_eq!(extraction.question.map(|q| q.prompt), Some("Second?".to_string()));
        assert_eq!(extraction.text, "Between.\n\nSecond?");
    }

    #[test]
    fn streaming_closing_fence_closes_the_open_block() {
        let text = "Intro\n\n```learnfold-question\nQ?\n- A\n- B\n```";
        let streaming = normalize_streaming_assistant_text(text, true);
        assert_eq!(streaming, normalize_assistant_text(text));
        assert!(streaming.question.is_some());
        assert!(!streaming.question_streaming);
        // Outside a Learnfold fence a trailing bare fence is still hidden.
        let opener = normalize_streaming_assistant_text("Intro\n```", true);
        assert_eq!(opener.display_text, "Intro");
    }

    #[test]
    fn streaming_prefix_never_shows_partial_fence_text() {
        let full = format!("Lead-in.\n\n{BLOCK}");
        for end in 0..=full.len() {
            if !full.is_char_boundary(end) {
                continue;
            }
            let partial = &full[..end];
            let normalized = normalize_streaming_assistant_text(partial, true);
            assert!(
                !normalized.display_text.contains("```"),
                "fence leaked at {end}: {:?}",
                normalized.display_text
            );
        }
    }

    // ── CoursePlanMarkdownTests ──

    const TREASURY: &str = "Here is a rigorous, calculation-heavy path.\n\n```learnfold-plan\n# Treasury Market Analysis\n**Summary:** Analyst-level Treasury valuation, rate risk, and curve analysis.\nOutcome: Price Treasuries, measure duration and convexity, and explain curve moves.\nStarting point: Knows that bond prices fall when yields rise.\nFocus: Rigorous duration, convexity, and curve math.\nDuration: 12 hours\n\n## Chapter 1: Valuation and yield\nObjective: Price Treasury securities from cash flows and quoted yields.\n- Pricing a Treasury note\n- Yield measures\n  - Worked example: a 10-year note\n  - Day-count conventions (explainer)\n\n## 2. Duration and convexity\nObjective: Measure and hedge interest-rate risk.\n- Duration\n- Convexity\n```";

    #[test]
    fn extracts_plan_and_hides_fence() {
        let extraction = extract_plan(TREASURY);
        assert_eq!(extraction.text, "Here is a rigorous, calculation-heavy path.");
        assert!(!extraction.is_incomplete);
        let Some(PlanBlock::Plan(plan)) = extraction.blocks.first() else {
            panic!("expected a parsed plan: {:?}", extraction.blocks);
        };
        assert_eq!(plan.title, "Treasury Market Analysis");
        assert_eq!(
            plan.summary,
            "Analyst-level Treasury valuation, rate risk, and curve analysis."
        );
        assert_eq!(plan.estimated_duration, "12 hours");
        assert_eq!(
            plan.chapters.iter().map(|c| c.title.as_str()).collect::<Vec<_>>(),
            vec!["Valuation and yield", "Duration and convexity"]
        );
        assert_eq!(
            plan.chapters[0].children[1]
                .children
                .iter()
                .map(|n| n.title.as_str())
                .collect::<Vec<_>>(),
            vec!["Worked example: a 10-year note", "Day-count conventions"]
        );
        assert_eq!(
            plan.chapters[0].children[1].children[1].role,
            Some(ChatPlanNodeRole::Explainer)
        );
        assert_eq!(
            plan.chapters[0].objective,
            "Price Treasury securities from cash flows and quoted yields."
        );
    }

    #[test]
    fn streaming_plan_fence_is_hidden_until_closed() {
        let partial = "Intro sentence.\n\n```learnfold-plan\n# Treasury";
        let extraction = extract_plan(partial);
        assert!(extraction.is_incomplete);
        assert!(extraction.blocks.is_empty());
        assert_eq!(extraction.text, "Intro sentence.");
    }

    #[test]
    fn missing_fields_produce_specific_issue() {
        let reply = "```learnfold-plan\n# Bonds\nSummary: A short course on bonds.\n## Pricing\n- Present value\n```";
        assert_eq!(
            extract_plan(reply).blocks,
            vec![PlanBlock::Invalid(
                "The plan is missing `Outcome:`, `Starting point:`, `Focus:`.".into()
            )]
        );
    }

    #[test]
    fn titles_keep_leading_years() {
        let reply = "```learnfold-plan\n# Crises\nSummary: Financial crises.\nOutcome: Explain crises.\nStarting point: Some history.\nFocus: Causes.\n## 1987 crash\n- 2008 collapse\n```";
        let Some(PlanBlock::Plan(plan)) = extract_plan(reply).blocks.into_iter().next() else {
            panic!("expected plan");
        };
        assert_eq!(plan.chapters[0].title, "1987 crash");
        assert_eq!(plan.chapters[0].children[0].title, "2008 collapse");
        assert_eq!(plan.estimated_duration, DEFAULT_PLAN_DURATION);
    }

    #[test]
    fn third_level_headings_become_subchapters() {
        let reply = "```learnfold-plan\n# Bonds\nSummary: s\nOutcome: o\nStarting point: p\nFocus: f\n## Pricing\n### Section one\n- Lesson A\n  - Lesson B\n- Lesson C (module)\n```";
        let Some(PlanBlock::Plan(plan)) = extract_plan(reply).blocks.into_iter().next() else {
            panic!("expected plan");
        };
        let chapter = &plan.chapters[0];
        assert_eq!(chapter.children.len(), 1);
        let section = &chapter.children[0];
        assert_eq!(section.role, Some(ChatPlanNodeRole::Subchapter));
        assert_eq!(
            section.children.iter().map(|n| n.title.as_str()).collect::<Vec<_>>(),
            vec!["Lesson A", "Lesson C"]
        );
        assert_eq!(section.children[0].children[0].title, "Lesson B");
        assert_eq!(section.children[1].role, Some(ChatPlanNodeRole::Module));
    }

    #[test]
    fn stripping_questions_also_hides_plan_fences() {
        let normalized = normalize_assistant_text(TREASURY);
        assert_eq!(normalized.display_text, "Here is a rigorous, calculation-heavy path.");
        assert_eq!(normalized.plans.len(), 1);
    }

    // ── Hermes envelopes (CourseExperienceStoreTests) ──

    #[test]
    fn remote_tool_call_requires_one_bare_allowlisted_envelope() {
        let response = r#"{"learnfold_tool_call":{"name":"present_course_plan","arguments":{"workspace_id":"workspace-1","plan_id":"swift-actors","revision":1,"title":"Swift Actors","chapters":[{"id":"one","title":"Foundations","objective":"Understand { isolation }","deliverables":[]}]}}}"#;
        let call = remote_tool_call(response).expect("call");
        assert_eq!(call.name, "present_course_plan");
        let arguments: Value = serde_json::from_str(&call.arguments_json).expect("json");
        assert_eq!(arguments["workspace_id"], "workspace-1");
        assert_eq!(arguments["plan_id"], "swift-actors");
        assert!(call.arguments_json.find("\"chapters\"") < call.arguments_json.find("\"plan_id\""));

        assert_eq!(remote_tool_call(&format!("Introduction\n{response}")), None);
        assert_eq!(remote_tool_call(&format!("```json\n{response}\n```")), None);
        // Swift's timeline hides only text that starts as an envelope, so
        // prose before one stays visible.
        assert!(!hidden_by_hermes_typing(&format!("Introduction\n{response}")));
        assert!(!hidden_by_hermes_typing(&format!("```json\n{response}\n```")));

        let update = r##"{"learnfold_tool_call":{"name":"native-editor-update-page","arguments":{"workspace_id":"workspace-1","page_id":"page-1","command":"replace_content","new_str":"# Example\n```swift\nprint(\"blue\")\n```"}}}"##;
        let update_call = remote_tool_call(update).expect("update call");
        assert_eq!(update_call.name, "native-editor-update-page");
        assert!(update_call.arguments_json.contains("```swift"));

        let bash = r#"{"learnfold_tool_call":{"name":"course_bash","arguments":{"workspace_id":"workspace-1","script":"find . -type f"}}}"#;
        let bash_call = remote_tool_call(bash).expect("bash call");
        assert_eq!(bash_call.name, COURSE_BASH_TOOL);
        assert!(bash_call.arguments_json.contains("find . -type f"));

        assert_eq!(
            remote_tool_call(r#"{"learnfold_tool_call":{"name":"shell_command","arguments":{}}}"#),
            None
        );
        assert_eq!(
            remote_tool_call(
                r#"{"learnfold_tool_call":{"name":"present_course_plan","arguments":{}},"extra":true}"#
            ),
            None
        );
    }

    fn hidden_by_hermes_typing(text: &str) -> bool {
        type_hermes_envelopes(vec![assistant_item("a", "t", text)], None).is_empty()
    }

    #[test]
    fn canonical_json_matches_darwin_sorted_keys_output() {
        let value: Value =
            serde_json::from_str(r#"{"script":"ls /workspace","b":1.0,"a":[2.5,{"z":null,"y":true}]}"#)
                .unwrap();
        assert_eq!(
            canonical_json(&value),
            r#"{"a":[2.5,{"y":true,"z":null}],"b":1,"script":"ls \/workspace"}"#
        );
    }

    #[test]
    fn cjk_numbered_options_parse_like_swift() {
        let block = "```learnfold-question\nLevel?\n一. 初学\n二. 进阶\n```";
        assert_eq!(
            extract_question(block).question.map(|q| q.options),
            Some(vec!["初学".to_string(), "进阶".to_string()])
        );
    }

    #[test]
    fn hermes_envelopes_hide_like_swift() {
        let call = r#"{"learnfold_tool_call":{"name":"course_bash","arguments":{"workspace_id":"w","script":"ls"}}}"#;
        // Malformed, prose-trailed and half-streamed envelopes leave no card.
        assert!(hidden_by_hermes_typing(r#"{"learnfold_tool_call":{"name":"course_bash"}}"#));
        assert!(hidden_by_hermes_typing(&format!("{call}\n\nNow I'll check the folder.")));
        let half = vec![assistant_item("a", "t", r#"{"learnfold_tool_call":{"name":"present_cou"#)];
        assert!(type_hermes_envelopes(half, Some("a")).is_empty());

        // A failed present_course_plan is hidden, not turned into a notice:
        // Swift sent the failure back to Hermes and showed nothing.
        let plan = r#"{"learnfold_tool_call":{"name":"present_course_plan","arguments":{"workspace_id":"w"}}}"#;
        let failed = "{\"learnfold_tool_result\":{\"name\":\"present_course_plan\",\"success\":false}}";
        let items = vec![
            user_item("u1", "t1", "Plan it"),
            assistant_item("a1", "t1", plan),
            user_item("u2", "t2", failed),
        ];
        let projected = project_course_items(type_hermes_envelopes(items, None), false);
        assert_eq!(projected.len(), 1);
        assert!(matches!(projected[0].content, HydratedConversationItemContent::User(_)));

        // A completed course_bash call stays as a typed tool (a work entry).
        let ok = "{\"learnfold_tool_result\":{\"name\":\"course_bash\",\"success\":true}}";
        let items = vec![
            user_item("u1", "t1", "Build it"),
            assistant_item("a1", "t1", call),
            user_item("u2", "t2", ok),
        ];
        let projected = project_course_items(type_hermes_envelopes(items, None), false);
        assert!(matches!(
            &projected[1].content,
            HydratedConversationItemContent::DynamicToolCall(data)
                if data.tool == COURSE_BASH_TOOL && data.status == AppOperationStatus::Completed
        ));
    }

    #[test]
    fn remote_tool_call_rejects_malformed_envelope() {
        let missing_arguments = r#"{"learnfold_tool_call":{"name":"native-editor-fetch"}}"#;
        assert_eq!(remote_tool_call(missing_arguments), None);
        assert!(hidden_by_hermes_typing(missing_arguments));
        let missing_closing_brace = r#"{"learnfold_tool_call":{"name":"native-editor-update-page","arguments":{"workspace_id":"workspace-1","page_id":"page-1","command":"update_content","expected_revision":1,"content_updates":[],"properties":{"generation_status":"generated"}}}"#;
        assert_eq!(remote_tool_call(missing_closing_brace), None);
        assert!(hidden_by_hermes_typing(missing_closing_brace));
        let other = r#"{"tool_call":{"name":"native-editor-fetch","arguments":{}}}"#;
        assert_eq!(remote_tool_call(other), None);
        assert!(!hidden_by_hermes_typing(other));
        assert!(!hidden_by_hermes_typing(
            "Hermes finished the lesson without requesting another tool."
        ));
    }

    #[test]
    fn partial_envelope_detection_only_matches_the_tool_key() {
        assert!(is_partial_tool_call_envelope("{"));
        assert!(is_partial_tool_call_envelope("{\"learnf"));
        assert!(is_partial_tool_call_envelope("{ \"learnfold_tool_call\": {\"na"));
        assert!(!is_partial_tool_call_envelope("{\"question\""));
        assert!(!is_partial_tool_call_envelope("Hello {"));
    }

    // ── Internal markers ──

    #[test]
    fn internal_instruction_policy_recognizes_tagged_and_legacy_prompts_only() {
        let tagged = "<learnfold_internal_course_instruction version=\"1\">\npurpose: approve_course_plan\nGenerate the approved lesson.\n</learnfold_internal_course_instruction>";
        let legacy_approval = "I approve course plan coffee, revision 1. Learnfold has already created every chapter. Use learnfold_generate_lesson and set generation_status to generated. Do not recreate the course structure.";
        let legacy_targeted = "This request was started from the Learn screen. Use native-editor-fetch, then native-editor-update-page. Keep the page pending_generation. Never generate siblings or later sections.";
        assert!(is_internal_instruction(tagged));
        assert!(is_internal_instruction(legacy_approval));
        assert!(is_internal_instruction(legacy_targeted));
        assert!(!is_internal_instruction(
            "I approve the plan. Please add a worked example about café history."
        ));
        assert!(!is_internal_instruction("Generate the next lesson when I ask for it."));
    }

    #[test]
    fn selection_prompt_projects_only_learner_question() {
        let prompt = "I selected the following passage from the native course page `Lesson`.\n\n<selected_course_passage page_id=\"lesson\" title=\"Lesson\">\nawait can interleave work\n</selected_course_passage>\n\nMy question: Can you show me a timeline?";
        assert_eq!(
            selection_question(prompt).as_deref(),
            Some("Can you show me a timeline?")
        );
        assert_eq!(
            learner_visible_text(prompt, true).as_deref(),
            Some("Can you show me a timeline?")
        );
        assert_eq!(learner_visible_text(prompt, false).as_deref(), Some(prompt));
    }

    #[test]
    fn page_and_remote_wrappers_project_learner_text() {
        let page = "I am reading this course page. Use it as context for my question.\n<current_course_page page_id=\"p\" title=\"T\" truncated=\"false\">\nbody\n</current_course_page>\n\nMy question: Why is the challenge random?";
        assert_eq!(
            page_context_question(page).as_deref(),
            Some("Why is the challenge random?")
        );
        assert_eq!(page_context_question("An ordinary question"), None);
        let remote = format!(
            "Instructions\n\n{REMOTE_PROTOCOL_MARKER}\n- rules{REMOTE_LEARNER_MARKER}{page}"
        );
        assert_eq!(
            learner_visible_text(&remote, false).as_deref(),
            Some("Why is the challenge random?")
        );
        let internal = format!(
            "{REMOTE_PROTOCOL_MARKER}{REMOTE_LEARNER_MARKER}{INTERNAL_INSTRUCTION_MARKER}\nbody"
        );
        assert_eq!(learner_visible_text(&internal, false), None);
        assert_eq!(
            learner_visible_text(r#"{"learnfold_tool_result":{"success":true}}"#, false),
            None
        );
    }

    fn user_item(id: &str, turn: &str, text: &str) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.into(),
            content: HydratedConversationItemContent::User(HydratedUserMessageData {
                text: text.into(),
                image_data_uris: vec![],
            }),
            source_turn_id: Some(turn.into()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: true,
        }
    }

    fn assistant_item(id: &str, turn: &str, text: &str) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.into(),
            content: HydratedConversationItemContent::Assistant(
                crate::conversation_uniffi::HydratedAssistantMessageData {
                    text: text.into(),
                    agent_nickname: None,
                    agent_role: None,
                    phase: None,
                },
            ),
            source_turn_id: Some(turn.into()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    #[test]
    fn course_projection_hides_internal_turns() {
        let items = vec![
            user_item("u1", "t1", "Explain OLED."),
            assistant_item("a1", "t1", "Sure."),
            user_item("u2", "t2", INTERNAL_INSTRUCTION_MARKER),
            assistant_item("a2", "t2", "Generating lesson."),
            user_item("u3", "t3", "Thanks"),
        ];
        let ids: Vec<String> = project_course_items(items, false)
            .into_iter()
            .map(|item| item.id)
            .collect();
        assert_eq!(ids, vec!["u1", "a1", "u3"]);
    }

    const ASSESSMENT_DISCUSSION_PROMPT: &str = "<learnfold_assessment_discussion version=\"1\">\n{\"assessment\":{\"id\":\"oxygen-loss\"},\"lesson\":\"Oxygen accepts electrons.\"}\n</learnfold_assessment_discussion>";

    fn with_turn_metadata(
        mut items: Vec<HydratedConversationItem>,
        mode: u8,
    ) -> Vec<HydratedConversationItem> {
        for item in &mut items {
            if mode != 0 {
                let index = match item.source_turn_id.as_deref() {
                    Some("t1") => Some(1),
                    Some("t2") => Some(2),
                    _ => Some(3),
                };
                item.source_turn_id = None;
                item.source_turn_index = if mode == 1 { index } else { None };
            }
        }
        items
    }

    #[test]
    fn course_projection_hides_assessment_control_and_keeps_live_and_restored_ai_opening() {
        let items = vec![
            user_item("control", "t1", ASSESSMENT_DISCUSSION_PROMPT),
            assistant_item("opening", "t1", "What happens to the proton gradient without oxygen?"),
            user_item("answer", "t2", "It collapses because electron transport stalls."),
            assistant_item("feedback", "t2", "Yes. How does that affect ATP production?"),
        ];
        // Live sources use turn IDs; restored sources may retain indices or no
        // turn metadata. All projections must hide exactly the control item.
        for mode in 0..3 {
            let projected = project_course_items(with_turn_metadata(items.clone(), mode), false);
            let ids: Vec<&str> = projected.iter().map(|item| item.id.as_str()).collect();
            assert_eq!(ids, vec!["opening", "answer", "feedback"], "metadata mode {mode}");
            let HydratedConversationItemContent::Assistant(opening) = &projected[0].content else {
                panic!("the AI's first question must remain an assistant message");
            };
            assert_eq!(opening.text, "What happens to the proton gradient without oxygen?");
        }
    }

    #[test]
    fn course_projection_assessment_control_ends_previous_internal_generation_suppression() {
        let items = vec![
            user_item("generation", "t1", INTERNAL_INSTRUCTION_MARKER),
            assistant_item("generation-reply", "t1", "Generated the lesson."),
            user_item("control", "t2", ASSESSMENT_DISCUSSION_PROMPT),
            assistant_item("opening", "t2", "Why does ATP production fall?"),
        ];
        for mode in 0..3 {
            let projected = project_course_items(with_turn_metadata(items.clone(), mode), false);
            let ids: Vec<&str> = projected.iter().map(|item| item.id.as_str()).collect();
            assert_eq!(ids, vec!["opening"], "metadata mode {mode}");
        }
    }

    #[test]
    fn assessment_control_quoted_generation_marker_does_not_hide_the_ai_question() {
        let control = format!(
            "{ASSESSMENT_DISCUSSION_PROMPT}\nQuoted lesson example: {INTERNAL_INSTRUCTION_MARKER}"
        );
        let projected = project_course_items(
            vec![
                user_item("control", "t1", &control),
                assistant_item("opening", "t1", "Which part of the lesson would you like to explain?"),
            ],
            false,
        );
        assert_eq!(projected.len(), 1);
        assert_eq!(projected[0].id, "opening");
    }

    #[test]
    fn assessment_control_is_hidden_through_remote_wrappers_without_hiding_the_reply() {
        let remote = format!(
            "Instructions\n\n{REMOTE_PROTOCOL_MARKER}\n- rules{REMOTE_LEARNER_MARKER}{ASSESSMENT_DISCUSSION_PROMPT}"
        );
        assert_eq!(learner_visible_text(&remote, false), None);
        let projected = project_course_items(
            vec![
                user_item("control", "t1", &remote),
                assistant_item("opening", "t1", "What supplies the energy for the pump?"),
            ],
            false,
        );
        assert_eq!(projected.len(), 1);
        assert_eq!(projected[0].id, "opening");
    }

    #[test]
    fn ordinary_learner_messages_quoting_assessment_controls_remain_visible() {
        let quoted = format!("What does this Markdown example mean?\n\n{ASSESSMENT_DISCUSSION_PROMPT}");
        assert_eq!(learner_visible_text(&quoted, false), Some(quoted.clone()));
        let projected = project_course_items(
            vec![
                user_item("question", "t1", &quoted),
                assistant_item("reply", "t1", "That marker starts an exercise discussion."),
            ],
            false,
        );
        let ids: Vec<&str> = projected.iter().map(|item| item.id.as_str()).collect();
        assert_eq!(ids, vec!["question", "reply"]);
    }

    #[test]
    fn hermes_envelopes_become_typed_tool_items() {
        let call = r#"{"learnfold_tool_call":{"name":"course_bash","arguments":{"workspace_id":"w","script":"ls"}}}"#;
        let result = "{\"learnfold_tool_result\":{\"call_id\":\"c\",\"name\":\"course_bash\",\"success\":false}}\n\nContinue the course task.";
        let items = vec![
            user_item("u1", "t1", "Build it"),
            assistant_item("a1", "t1", call),
            user_item("u2", "t2", result),
            assistant_item("a2", "t2", "Done."),
        ];
        let typed = type_hermes_envelopes(items, None);
        assert_eq!(typed.len(), 3);
        let HydratedConversationItemContent::DynamicToolCall(tool) = &typed[1].content else {
            panic!("expected tool item");
        };
        assert_eq!(tool.tool, "course_bash");
        assert_eq!(tool.status, AppOperationStatus::Failed);
        assert_eq!(tool.success, Some(false));

        let streaming = vec![assistant_item("a9", "t9", "{\"learnfold_to")];
        assert!(type_hermes_envelopes(streaming.clone(), Some("a9")).is_empty());
        assert_eq!(type_hermes_envelopes(streaming, None).len(), 1);
    }
}
