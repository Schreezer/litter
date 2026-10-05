//! What a thread's latest request is doing right now, typed for
//! learner-facing status lines (the background task banner, the watch).
//!
//! `last_tool_label` names the newest tool item with its wire name ("MCP
//! native-editor-fetch") and keeps naming it after the tool finished. This
//! projection reports a kind, a learner-safe subject and a few counts
//! instead; platforms only pick the wording.
//!
//! Tool arguments are capped at 4 KiB and results at 128 KiB during
//! hydration, and `serde_json` keeps the key order the model emitted, so a
//! long lesson write usually does not parse. Every argument and result read
//! here is best effort: a parse failure only drops the subject.

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

use serde_json::Value;

use crate::conversation_uniffi::{
    HydratedCommandActionKind, HydratedCommandExecutionData, HydratedConversationItem,
    HydratedConversationItemContent, HydratedDynamicToolCallData, HydratedReasoningData,
};
use crate::source::ChatRuntime;
use crate::source::normalize::{
    self, COURSE_BASH_TOOL, HERMES_ENVELOPE_NAMESPACE, PRESENT_PLAN_TOOL,
};
use crate::types::AppOperationStatus;

use super::boundary::is_pure_exploration;
use super::snapshot::ThreadSnapshot;

const SUBJECT_CHARACTER_LIMIT: usize = 60;
const PAGE_URL_PREFIX: &str = "native-editor://page/";
const OUTLINE_PAGE_ID: &str = "self";
const FETCH_TOOL: &str = "native-editor-fetch";
const SEARCH_TOOL: &str = "native-editor-search";
const CREATE_PAGES_TOOL: &str = "native-editor-create-pages";
const UPDATE_PAGE_TOOL: &str = "native-editor-update-page";
const MOVE_PAGES_TOOL: &str = "native-editor-move-pages";
const DUPLICATE_PAGE_TOOL: &str = "native-editor-duplicate-page";
const ASYNC_TASK_TOOL: &str = "native-editor-get-async-task";
const GENERATE_LESSON_TOOL: &str = "learnfold_generate_lesson";
const APPEND_LESSON_SECTION_TOOL: &str = "learnfold_append_lesson_section";

/// What the agent is doing. Course kinds come from Learnfold's course
/// tools; the rest from generic Codex items.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AppTurnActivityKind {
    /// The turn started and nothing of it has arrived yet.
    Starting,
    /// Reasoning, or between tool calls.
    Thinking,
    /// Writing the reply.
    Responding,
    ReadingCourse,
    ReadingCourseOutline,
    SearchingCourse,
    /// Re-reading a page this request already wrote.
    VerifyingCoursePage,
    WritingCoursePage,
    UpdatingCourseDetails,
    AddingCoursePages,
    OrganizingCourse,
    /// Polling an async course write.
    SavingCourseChanges,
    PlanningCourse,
    CheckingCourseFiles,
    RunningCommand,
    ReadingFiles,
    SearchingFiles,
    EditingFiles,
    SearchingWeb,
    UsingTool,
    Delegating,
    GeneratingImage,
}

/// The current activity of a thread's latest request.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AppTurnActivity {
    pub kind: AppTurnActivityKind,
    /// Learner-safe detail: a page title, search query, file name, command
    /// or reasoning headline. One line of at most 60 characters plus "…";
    /// never JSON, ids or wire tool names.
    pub subject: Option<String>,
    /// The course page the step concerns, without the `native-editor://page/`
    /// prefix. Lets the platform name the page when `subject` is `None`.
    pub page_id: Option<String>,
    /// The tool item behind `kind` is still running.
    pub is_running: bool,
    /// Files in the change, pages created, files read or delegation targets.
    pub unit_count: u32,
    /// Items of this kind in the request so far.
    pub step_count: u32,
    /// Distinct course pages fetched in this request (the outline excluded).
    pub course_pages_read: u32,
    /// Course pages whose content this request saved successfully.
    pub course_pages_written: u32,
}

/// The activity of the thread's latest request: the items after its last
/// learner message. Tool-result envelopes are not learner messages, so a
/// Hermes request keeps its scope across the turns that carry tool results.
/// `None` for a thread with no items and no running turn.
pub(crate) fn current_turn_activity(thread: &ThreadSnapshot) -> Option<AppTurnActivity> {
    if thread.items.is_empty() && thread.active_turn_id.is_none() {
        return None;
    }
    if let Some(turn_id) = thread.active_turn_id.as_deref()
        && !thread
            .items
            .iter()
            .rev()
            .any(|item| item.source_turn_id.as_deref() == Some(turn_id))
        && !continues_open_request(thread, turn_id)
    {
        return Some(empty_activity(AppTurnActivityKind::Starting));
    }
    let scope = request_scope(&thread.items);
    if ChatRuntime::from_id(&thread.agent_runtime_kind) == ChatRuntime::Hermes {
        let typed = normalize::type_hermes_envelopes(scope.to_vec(), None);
        return Some(classify_request(&typed));
    }
    Some(classify_request(scope))
}

fn empty_activity(kind: AppTurnActivityKind) -> AppTurnActivity {
    AppTurnActivity {
        kind,
        subject: None,
        page_id: None,
        is_running: false,
        unit_count: 0,
        step_count: 0,
        course_pages_read: 0,
        course_pages_written: 0,
    }
}

/// A tool result sent back as a new turn continues the open request. Until
/// the server echoes it, only the local overlay bound to the turn shows it.
fn continues_open_request(thread: &ThreadSnapshot, turn_id: &str) -> bool {
    thread.local_overlay_items.iter().any(|item| {
        item.source_turn_id.as_deref() == Some(turn_id)
            && matches!(
                &item.content,
                HydratedConversationItemContent::User(data)
                    if normalize::is_tool_result_envelope(&data.text)
            )
    })
}

fn request_scope(items: &[HydratedConversationItem]) -> &[HydratedConversationItem] {
    let start = items
        .iter()
        .rposition(|item| {
            matches!(
                &item.content,
                HydratedConversationItemContent::User(data)
                    if !normalize::is_tool_result_envelope(&data.text)
            )
        })
        .map_or(0, |index| index + 1);
    &items[start..]
}

// ── Classification ────────────────────────────────────────────────────────

/// One classified item of the request.
#[derive(Debug, Clone)]
struct Step {
    kind: AppTurnActivityKind,
    subject: Option<String>,
    page_id: Option<String>,
    unit_count: u32,
    is_running: bool,
    /// Tool items fall back to `Thinking` once they finish.
    is_tool: bool,
}

impl Step {
    fn new(kind: AppTurnActivityKind) -> Self {
        Self {
            kind,
            subject: None,
            page_id: None,
            unit_count: 0,
            is_running: false,
            is_tool: false,
        }
    }

    fn tool(kind: AppTurnActivityKind, is_running: bool) -> Self {
        Self {
            is_running,
            is_tool: true,
            ..Self::new(kind)
        }
    }

    fn subject(mut self, subject: Option<String>) -> Self {
        self.subject = subject;
        self
    }
}

/// Course facts gathered while walking the request in order.
#[derive(Default)]
struct CourseProgress {
    read_pages: HashSet<String>,
    /// Pages with a successful content write, keyed by page id (or by item
    /// id when the arguments were too truncated to name the page).
    written: HashSet<String>,
    written_pages: HashSet<String>,
    /// Titles the request itself set through update-page properties.
    titles: HashMap<String, String>,
}

fn classify_request(scope: &[HydratedConversationItem]) -> AppTurnActivity {
    let mut course = CourseProgress::default();
    let steps: Vec<Option<Step>> = scope
        .iter()
        .map(|item| classify_item(item, &mut course))
        .collect();
    let counted = |kind: AppTurnActivityKind| {
        steps
            .iter()
            .flatten()
            .filter(|step| step.kind == kind)
            .count() as u32
    };
    let finish = |step: Step| {
        let step_count = counted(step.kind);
        let subject = step.subject.or_else(|| {
            step.page_id
                .as_deref()
                .and_then(|page_id| resolve_page_title(scope, page_id, &course.titles))
        });
        AppTurnActivity {
            kind: step.kind,
            subject,
            page_id: step.page_id,
            is_running: step.is_running,
            unit_count: step.unit_count,
            step_count,
            course_pages_read: course.read_pages.len() as u32,
            course_pages_written: course.written.len() as u32,
        }
    };

    let Some(newest) = steps.iter().rposition(Option::is_some) else {
        return finish(Step::new(AppTurnActivityKind::Starting));
    };
    let step = steps[newest].clone().expect("newest step exists");
    if !step.is_tool || step.is_running {
        return finish(step);
    }
    // Parallel tool calls: one that is still running in the same burst
    // describes the work better than the one that just finished.
    let still_running = steps[..newest]
        .iter()
        .rev()
        .flatten()
        .take_while(|step| step.is_tool)
        .find(|step| step.is_running)
        .cloned();
    // A finished tool with nothing newer means the agent is deciding what
    // to do next; naming the old tool would be stale.
    finish(still_running.unwrap_or_else(|| Step::new(AppTurnActivityKind::Thinking)))
}

fn classify_item(item: &HydratedConversationItem, course: &mut CourseProgress) -> Option<Step> {
    use AppTurnActivityKind as Kind;
    match &item.content {
        HydratedConversationItemContent::User(_)
        | HydratedConversationItemContent::UserInputResponse(_)
        | HydratedConversationItemContent::Divider(_)
        | HydratedConversationItemContent::Note(_)
        | HydratedConversationItemContent::TodoList(_)
        | HydratedConversationItemContent::TurnDiff(_)
        | HydratedConversationItemContent::Error(_)
        | HydratedConversationItemContent::ImageView(_) => None,
        HydratedConversationItemContent::Reasoning(data) => {
            Some(Step::new(Kind::Thinking).subject(reasoning_headline(data)))
        }
        HydratedConversationItemContent::Assistant(data) => {
            // Envelope prose is a tool call in transit, not a reply. Text
            // deltas do not refresh summaries, so even an empty message
            // counts as replying.
            if normalize::is_tool_call_envelope(&data.text)
                || normalize::is_partial_tool_call_envelope(&data.text)
            {
                None
            } else if normalize::contains_plan_fence(&data.text) {
                Some(Step::new(Kind::PlanningCourse))
            } else {
                Some(Step::new(Kind::Responding))
            }
        }
        HydratedConversationItemContent::ProposedPlan(_)
        | HydratedConversationItemContent::CodeReview(_) => Some(Step::new(Kind::Responding)),
        HydratedConversationItemContent::CommandExecution(data) => Some(command_step(data)),
        HydratedConversationItemContent::FileChange(data) => {
            let mut step = Step::tool(Kind::EditingFiles, is_running(data.status)).subject(
                data.changes
                    .first()
                    .and_then(|change| file_name(&change.path))
                    .as_deref()
                    .and_then(clean_subject),
            );
            step.unit_count = data.changes.len() as u32;
            Some(step)
        }
        HydratedConversationItemContent::McpToolCall(data) => {
            if normalize::is_internal_course_server(&data.server) {
                return Some(course_step(
                    &CourseCall {
                        name: normalize::course_tool_name(&data.tool),
                        item_id: &item.id,
                        arguments: data.arguments_json.as_deref(),
                        status: data.status,
                        failed: data.error_message.is_some(),
                    },
                    course,
                ));
            }
            let tool = humanized_words(&data.tool);
            let server = capitalized(&humanized_words(&data.server));
            let label = match (server.is_empty(), tool.is_empty()) {
                (false, false) => format!("{server} · {tool}"),
                (false, true) => server,
                _ => tool,
            };
            Some(
                Step::tool(Kind::UsingTool, is_running(data.status)).subject(clean_subject(&label)),
            )
        }
        HydratedConversationItemContent::DynamicToolCall(data) => {
            if is_course_dynamic_tool(data) {
                return Some(course_step(
                    &CourseCall {
                        name: normalize::course_tool_name(&data.tool),
                        item_id: &item.id,
                        arguments: data.arguments_json.as_deref(),
                        status: data.status,
                        failed: data.success == Some(false),
                    },
                    course,
                ));
            }
            let label = data
                .display
                .as_ref()
                .map(|display| display.title.trim())
                .filter(|title| !title.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| humanized_dynamic_tool(data));
            Some(
                Step::tool(Kind::UsingTool, is_running(data.status)).subject(clean_subject(&label)),
            )
        }
        HydratedConversationItemContent::MultiAgentAction(data) => {
            let mut step = Step::tool(Kind::Delegating, is_running(data.status));
            step.unit_count = data.targets.len() as u32;
            Some(step)
        }
        HydratedConversationItemContent::WebSearch(data) => Some(
            Step::tool(Kind::SearchingWeb, data.is_in_progress).subject(clean_subject(&data.query)),
        ),
        HydratedConversationItemContent::ImageGeneration(data) => {
            Some(Step::tool(Kind::GeneratingImage, is_running(data.status)))
        }
        HydratedConversationItemContent::Widget(data) => Some(
            Step::tool(Kind::UsingTool, !data.is_finalized).subject(clean_subject(&data.title)),
        ),
    }
}

fn is_running(status: AppOperationStatus) -> bool {
    matches!(
        status,
        AppOperationStatus::Pending | AppOperationStatus::InProgress
    )
}

fn command_step(data: &HydratedCommandExecutionData) -> Step {
    use AppTurnActivityKind as Kind;
    let running = is_running(data.status);
    if !is_pure_exploration(data) {
        return Step::tool(Kind::RunningCommand, running)
            .subject(clean_subject(strip_cd_prefix(&data.command)));
    }
    let searches: Vec<_> = data
        .actions
        .iter()
        .filter(|action| action.kind == HydratedCommandActionKind::Search)
        .collect();
    if !searches.is_empty() {
        let mut step = Step::tool(Kind::SearchingFiles, running).subject(
            searches
                .iter()
                .find_map(|action| action.query.as_deref())
                .and_then(clean_subject),
        );
        step.unit_count = searches.len() as u32;
        return step;
    }
    let subject = data.actions.iter().find_map(|action| {
        action
            .name
            .as_deref()
            .filter(|name| !name.trim().is_empty())
            .map(str::to_string)
            .or_else(|| action.path.as_deref().and_then(file_name))
    });
    let mut step =
        Step::tool(Kind::ReadingFiles, running).subject(subject.as_deref().and_then(clean_subject));
    step.unit_count = data.actions.len() as u32;
    step
}

/// Drops leading `cd <path> &&` (or `;`) hops, which only repeat the cwd.
fn strip_cd_prefix(command: &str) -> &str {
    let mut rest = command.trim();
    while let Some(after_cd) = rest.strip_prefix("cd ") {
        let after_cd = after_cd.trim_start();
        let path_end = match after_cd.chars().next() {
            Some(quote @ ('"' | '\'')) => after_cd[1..].find(quote).map(|index| index + 2),
            Some(_) => Some(
                after_cd
                    .find(|c: char| c.is_whitespace() || c == '&' || c == ';')
                    .unwrap_or(after_cd.len()),
            ),
            None => None,
        };
        let Some(path_end) = path_end else {
            break;
        };
        let tail = after_cd[path_end..].trim_start();
        let Some(next) = tail.strip_prefix("&&").or_else(|| tail.strip_prefix(';')) else {
            break;
        };
        let next = next.trim_start();
        if next.is_empty() {
            break;
        }
        rest = next;
    }
    rest
}

// ── Course tools ──────────────────────────────────────────────────────────

struct CourseCall<'a> {
    /// Tool name without the direct-namespace prefix.
    name: &'a str,
    item_id: &'a str,
    arguments: Option<&'a str>,
    status: AppOperationStatus,
    /// The tool reported an error even if the call itself completed.
    failed: bool,
}

impl CourseCall<'_> {
    fn succeeded(&self) -> bool {
        self.status == AppOperationStatus::Completed && !self.failed
    }

    fn was_rejected(&self) -> bool {
        self.failed
            || matches!(
                self.status,
                AppOperationStatus::Failed | AppOperationStatus::Declined
            )
    }
}

/// Course tools reach Codex as dynamic tools on remote servers and as
/// typed Hermes envelopes; Apple's lesson tools arrive bare.
fn is_course_dynamic_tool(data: &HydratedDynamicToolCallData) -> bool {
    normalize::is_internal_course_dynamic_tool(data)
        || data.namespace.as_deref() == Some(HERMES_ENVELOPE_NAMESPACE)
        || matches!(
            normalize::course_tool_name(&data.tool),
            COURSE_BASH_TOOL | GENERATE_LESSON_TOOL | APPEND_LESSON_SECTION_TOOL
        )
}

fn course_step(call: &CourseCall<'_>, course: &mut CourseProgress) -> Step {
    use AppTurnActivityKind as Kind;
    let running = is_running(call.status);
    let parsed = call
        .arguments
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok());
    let argument = |key: &str| string_argument(parsed.as_ref(), call.arguments, key);
    match call.name {
        FETCH_TOOL => match argument("id").map(|id| normalized_page_id(&id)) {
            Some(id) if id == OUTLINE_PAGE_ID => Step::tool(Kind::ReadingCourseOutline, running),
            Some(id) => {
                if !call.was_rejected() {
                    course.read_pages.insert(id.clone());
                }
                let kind = if course.written_pages.contains(&id) {
                    Kind::VerifyingCoursePage
                } else {
                    Kind::ReadingCourse
                };
                let mut step = Step::tool(kind, running);
                step.page_id = Some(id);
                step
            }
            None => Step::tool(Kind::ReadingCourse, running),
        },
        SEARCH_TOOL => Step::tool(Kind::SearchingCourse, running)
            .subject(argument("query").as_deref().and_then(clean_subject)),
        UPDATE_PAGE_TOOL => {
            let page_id = argument("page_id").map(|id| normalized_page_id(&id));
            let title = parsed
                .as_ref()
                .and_then(|value| value.pointer("/properties/title"))
                .and_then(Value::as_str)
                .and_then(clean_subject);
            if let (Some(page_id), Some(title)) = (page_id.as_ref(), title.as_ref()) {
                course.titles.insert(page_id.clone(), title.clone());
            }
            let trashes = parsed
                .as_ref()
                .and_then(|value| value.get("in_trash"))
                .and_then(Value::as_bool)
                == Some(true);
            let kind = match argument("command").as_deref() {
                Some("trash") => Kind::OrganizingCourse,
                Some("update_properties") if trashes => Kind::OrganizingCourse,
                Some("update_properties") => Kind::UpdatingCourseDetails,
                // Any content command, or one lost to truncation.
                _ => Kind::WritingCoursePage,
            };
            if kind == Kind::WritingCoursePage && call.succeeded() {
                match page_id.as_ref() {
                    Some(page_id) => {
                        course.written.insert(page_id.clone());
                        course.written_pages.insert(page_id.clone());
                    }
                    None => {
                        course.written.insert(format!("item:{}", call.item_id));
                    }
                }
            }
            let mut step = Step::tool(kind, running).subject(title);
            step.page_id = page_id;
            step
        }
        CREATE_PAGES_TOOL => {
            let pages = parsed
                .as_ref()
                .and_then(|value| value.get("pages"))
                .and_then(Value::as_array);
            let mut step = Step::tool(Kind::AddingCoursePages, running).subject(
                pages
                    .and_then(|pages| pages.first())
                    .and_then(|page| page.pointer("/properties/title"))
                    .and_then(Value::as_str)
                    .and_then(clean_subject),
            );
            step.unit_count = pages.map_or(0, |pages| pages.len() as u32);
            step
        }
        MOVE_PAGES_TOOL | DUPLICATE_PAGE_TOOL => Step::tool(Kind::OrganizingCourse, running),
        ASYNC_TASK_TOOL => Step::tool(Kind::SavingCourseChanges, running),
        PRESENT_PLAN_TOOL => Step::tool(Kind::PlanningCourse, running),
        // The script is shell code, never a learner-facing subject.
        COURSE_BASH_TOOL => Step::tool(Kind::CheckingCourseFiles, running),
        GENERATE_LESSON_TOOL | APPEND_LESSON_SECTION_TOOL => {
            if call.succeeded() {
                course.written.insert(format!("item:{}", call.item_id));
            }
            Step::tool(Kind::WritingCoursePage, running)
        }
        _ => Step::tool(Kind::UsingTool, running),
    }
}

/// A top-level string argument. When the arguments were truncated, falls
/// back to scanning the text before the cut.
fn string_argument(parsed: Option<&Value>, raw: Option<&str>, key: &str) -> Option<String> {
    let value = match parsed {
        Some(parsed) => parsed.get(key)?.as_str().map(str::to_string),
        None => leading_string_field(raw?, key),
    }?;
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

/// Finds `"key": "value"` in possibly truncated JSON text. Keys inside JSON
/// strings are escaped (`\"key\"`), so they never match. Meant for flat
/// objects whose key does not also appear in a nested object.
fn leading_string_field(text: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let mut search_from = 0;
    while let Some(offset) = text[search_from..].find(&needle) {
        let start = search_from + offset;
        search_from = start + needle.len();
        if text[..start].ends_with('\\') {
            continue;
        }
        let rest = text[search_from..].trim_start();
        let Some(rest) = rest.strip_prefix(':') else {
            continue;
        };
        let rest = rest.trim_start();
        if !rest.starts_with('"') {
            continue;
        }
        let end = string_literal_end(rest)?;
        return serde_json::from_str::<String>(&rest[..end]).ok();
    }
    None
}

/// Byte length of the JSON string literal at the start of `text`.
fn string_literal_end(text: &str) -> Option<usize> {
    let mut escaped = false;
    for (index, c) in text.char_indices().skip(1) {
        match c {
            _ if escaped => escaped = false,
            '\\' => escaped = true,
            '"' => return Some(index + 1),
            _ => {}
        }
    }
    None
}

fn normalized_page_id(raw: &str) -> String {
    let trimmed = raw.trim();
    match trimmed.strip_prefix(PAGE_URL_PREFIX) {
        Some(rest) => rest
            .split(['/', '?', '#'])
            .next()
            .unwrap_or(rest)
            .to_string(),
        None => trimmed.to_string(),
    }
}

// ── Page titles ───────────────────────────────────────────────────────────

/// The title of a page the request touched, from what the request itself
/// set or received: update-page properties, then create-pages and search
/// results, then a fetch of that page. Parses at most one result.
fn resolve_page_title(
    scope: &[HydratedConversationItem],
    page_id: &str,
    titles: &HashMap<String, String>,
) -> Option<String> {
    if let Some(title) = titles.get(page_id) {
        return Some(title.clone());
    }
    for tool in [CREATE_PAGES_TOOL, SEARCH_TOOL, FETCH_TOOL] {
        for item in scope.iter().rev() {
            let Some((name, arguments, result)) = completed_course_result(item) else {
                continue;
            };
            if name != tool {
                continue;
            }
            if tool == FETCH_TOOL {
                if !result.contains(page_id)
                    || fetched_page_id(arguments).as_deref() != Some(page_id)
                {
                    continue;
                }
            } else if !lists_page_id(result, page_id) {
                // Every listed page names its parent; a page that is only a
                // parent here has no title in this result.
                continue;
            }
            // The first candidate settles it, found or not.
            return result_page_title(result, page_id, tool == FETCH_TOOL)
                .as_deref()
                .and_then(clean_subject);
        }
    }
    None
}

/// Whether a page list carries `page_id` as an entry's own `"id"`, not only
/// as a `parent.page_id` or URL. Reads compact, pretty-printed and
/// string-escaped JSON without parsing it.
fn lists_page_id(result: &str, page_id: &str) -> bool {
    result.match_indices(page_id).any(|(start, _)| {
        let before = &result[..start];
        let before = before.strip_suffix(PAGE_URL_PREFIX).unwrap_or(before);
        let Some(before) = before.strip_suffix('"') else {
            return false;
        };
        let before = before.strip_suffix('\\').unwrap_or(before).trim_end();
        let Some(before) = before.strip_suffix(':') else {
            return false;
        };
        let before = before.trim_end();
        let Some(before) = before.strip_suffix('"') else {
            return false;
        };
        let before = before.strip_suffix('\\').unwrap_or(before);
        before
            .strip_suffix("id")
            .is_some_and(|key| key.ends_with('"'))
    })
}

fn fetched_page_id(arguments: Option<&str>) -> Option<String> {
    let parsed = arguments.and_then(|raw| serde_json::from_str::<Value>(raw).ok());
    string_argument(parsed.as_ref(), arguments, "id").map(|id| normalized_page_id(&id))
}

/// Name, arguments and result text of a successful course tool call.
fn completed_course_result(item: &HydratedConversationItem) -> Option<(&str, Option<&str>, &str)> {
    match &item.content {
        HydratedConversationItemContent::McpToolCall(data)
            if normalize::is_internal_course_server(&data.server)
                && data.status == AppOperationStatus::Completed
                && data.error_message.is_none() =>
        {
            let result = data
                .structured_content_json
                .as_deref()
                .or(data.content_summary.as_deref())?;
            Some((
                normalize::course_tool_name(&data.tool),
                data.arguments_json.as_deref(),
                result,
            ))
        }
        HydratedConversationItemContent::DynamicToolCall(data)
            if is_course_dynamic_tool(data)
                && data.status == AppOperationStatus::Completed
                && data.success != Some(false) =>
        {
            Some((
                normalize::course_tool_name(&data.tool),
                data.arguments_json.as_deref(),
                data.content_summary.as_deref()?,
            ))
        }
        _ => None,
    }
}

/// Reads a page title out of a fetch result (`title`) or a page list
/// (`results[].id` / `title`).
fn result_page_title(result: &str, page_id: &str, is_fetch: bool) -> Option<String> {
    let Ok(mut value) = serde_json::from_str::<Value>(result) else {
        // A fetch of a long page is cut mid-Markdown; its top-level title
        // may still sit before the cut.
        return is_fetch
            .then(|| leading_string_field(result, "title"))
            .flatten();
    };
    // MCP text content wraps the JSON once more.
    if let Some(inner) = value
        .get("text")
        .and_then(Value::as_str)
        .and_then(|text| serde_json::from_str::<Value>(text).ok())
    {
        value = inner;
    }
    if is_fetch {
        return value.get("title")?.as_str().map(str::to_string);
    }
    value
        .get("results")?
        .as_array()?
        .iter()
        .find(|entry| {
            entry
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| normalized_page_id(id) == page_id)
        })?
        .get("title")?
        .as_str()
        .map(str::to_string)
}

// ── Subjects ──────────────────────────────────────────────────────────────

/// One learner-safe line: whitespace collapsed, `**` and backticks removed,
/// at most 60 characters plus "…". Drops JSON and anything naming
/// Learnfold's wire tools.
fn clean_subject(raw: &str) -> Option<String> {
    let unmarked = raw.replace("**", "").replace('`', "");
    let line = unmarked.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.is_empty() || line.starts_with('{') || line.starts_with('[') {
        return None;
    }
    let lowered = line.to_ascii_lowercase();
    if ["native-editor", "learnfold_", "mcp__"]
        .iter()
        .any(|marker| lowered.contains(marker))
        || uuid_pattern().is_match(&line)
    {
        return None;
    }
    if line.chars().count() <= SUBJECT_CHARACTER_LIMIT {
        return Some(line);
    }
    let kept: String = line.chars().take(SUBJECT_CHARACTER_LIMIT).collect();
    Some(format!("{}…", kept.trim_end()))
}

/// Page, node and task ids are UUIDs.
fn uuid_pattern() -> &'static regex::Regex {
    static PATTERN: OnceLock<regex::Regex> = OnceLock::new();
    PATTERN.get_or_init(|| {
        regex::Regex::new(r"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
            .expect("valid uuid pattern")
    })
}

fn bold_span_pattern() -> &'static regex::Regex {
    static PATTERN: OnceLock<regex::Regex> = OnceLock::new();
    PATTERN.get_or_init(|| regex::Regex::new(r"\*\*([^*\n]+)\*\*").expect("valid bold pattern"))
}

/// The newest reasoning headline. Codex opens each summary part with a bold
/// line; live summary deltas are appended into `content` until the item
/// completes.
fn reasoning_headline(data: &HydratedReasoningData) -> Option<String> {
    let parts = if data.summary.iter().any(|part| !part.trim().is_empty()) {
        &data.summary
    } else {
        &data.content
    };
    let part = parts.iter().rev().find(|part| !part.trim().is_empty())?;
    let headline = bold_span_pattern()
        .captures_iter(part)
        .filter_map(|captures| captures.get(1))
        .map(|found| found.as_str())
        .filter(|text| !text.trim().is_empty())
        .last()
        .or_else(|| part.lines().find(|line| !line.trim().is_empty()))?;
    clean_subject(headline)
}

fn file_name(path: &str) -> Option<String> {
    let name = path.trim().trim_end_matches(['/', '\\']);
    let name = name.rsplit(['/', '\\']).next().unwrap_or(name);
    (!name.is_empty()).then(|| name.to_string())
}

/// `create_issue`, `create-issue` and `createIssue` all read "create issue".
fn humanized_words(raw: &str) -> String {
    let mut spaced = String::with_capacity(raw.len() + 4);
    let mut previous_lowercase = false;
    for c in raw.chars() {
        if matches!(c, '_' | '-' | '.' | '/' | ':') {
            spaced.push(' ');
            previous_lowercase = false;
            continue;
        }
        if c.is_uppercase() && previous_lowercase {
            spaced.push(' ');
        }
        previous_lowercase = c.is_lowercase() || c.is_ascii_digit();
        spaced.extend(c.to_lowercase());
    }
    spaced.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn capitalized(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// `mcp__linear__create_issue` (an MCP tool routed as a dynamic tool) reads
/// "Linear · create issue"; other names are humanized as they are.
fn humanized_dynamic_tool(data: &HydratedDynamicToolCallData) -> String {
    if let Some(rest) = data.tool.strip_prefix("mcp__")
        && let Some((server, tool)) = rest.split_once("__")
    {
        return format!(
            "{} · {}",
            capitalized(&humanized_words(server)),
            humanized_words(tool)
        );
    }
    capitalized(&humanized_words(&data.tool))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversation_uniffi::{
        HydratedCommandActionData, HydratedFileChangeData, HydratedFileChangeEntryData,
        HydratedMcpToolCallData, HydratedReasoningData,
    };
    use crate::store::chat::{assistant_item, tool_item, user_item};
    use crate::types::{ThreadInfo, ThreadSummaryStatus};
    use serde_json::json;

    const PAGE: &str = "4f6c2b1a-0d3e-4c7a-9b52-8e1f0a6d3c21";
    const OTHER_PAGE: &str = "9a1d77e0-5b2c-4f8e-a316-2c7d9e0b4f58";

    fn thread(items: Vec<HydratedConversationItem>) -> ThreadSnapshot {
        let mut thread = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "thread".into(),
                title: None,
                model: None,
                status: ThreadSummaryStatus::Idle,
                preview: None,
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                forked_from_id: None,
                agent_status: None,
                created_at: None,
                updated_at: None,
            },
        );
        thread.items = items;
        thread
    }

    fn activity(items: Vec<HydratedConversationItem>) -> AppTurnActivity {
        current_turn_activity(&thread(items)).expect("activity")
    }

    fn mcp_item(
        id: &str,
        tool: &str,
        status: AppOperationStatus,
        arguments: Value,
        structured: Option<Value>,
    ) -> HydratedConversationItem {
        mcp_item_with_raw_arguments(
            id,
            tool,
            status,
            serde_json::to_string_pretty(&arguments).unwrap(),
            structured,
        )
    }

    fn mcp_item_with_raw_arguments(
        id: &str,
        tool: &str,
        status: AppOperationStatus,
        arguments_json: String,
        structured: Option<Value>,
    ) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.to_string(),
            content: HydratedConversationItemContent::McpToolCall(HydratedMcpToolCallData {
                server: "learnfold_course".to_string(),
                tool: tool.to_string(),
                status,
                duration_ms: None,
                arguments_json: Some(arguments_json),
                content_summary: None,
                structured_content_json: structured
                    .map(|value| serde_json::to_string_pretty(&value).unwrap()),
                raw_output_json: None,
                error_message: None,
                progress_messages: Vec::new(),
                computer_use: None,
            }),
            source_turn_id: Some("t1".to_string()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn running(id: &str, tool: &str, arguments: Value) -> HydratedConversationItem {
        mcp_item(id, tool, AppOperationStatus::InProgress, arguments, None)
    }

    fn done(id: &str, tool: &str, arguments: Value) -> HydratedConversationItem {
        mcp_item(id, tool, AppOperationStatus::Completed, arguments, None)
    }

    fn request() -> HydratedConversationItem {
        user_item("u1", "Write the lesson", Some("t1"))
    }

    fn reasoning(id: &str, summary: Vec<&str>, content: Vec<&str>) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.to_string(),
            content: HydratedConversationItemContent::Reasoning(HydratedReasoningData {
                summary: summary.into_iter().map(str::to_string).collect(),
                content: content.into_iter().map(str::to_string).collect(),
            }),
            source_turn_id: Some("t1".to_string()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn command(
        id: &str,
        command: &str,
        status: AppOperationStatus,
        actions: Vec<HydratedCommandActionData>,
    ) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.to_string(),
            content: HydratedConversationItemContent::CommandExecution(
                HydratedCommandExecutionData {
                    command: command.to_string(),
                    cwd: "/repo".to_string(),
                    status,
                    output: None,
                    exit_code: None,
                    duration_ms: None,
                    process_id: None,
                    actions,
                },
            ),
            source_turn_id: Some("t1".to_string()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn action(
        kind: HydratedCommandActionKind,
        name: Option<&str>,
        path: Option<&str>,
        query: Option<&str>,
    ) -> HydratedCommandActionData {
        HydratedCommandActionData {
            kind,
            command: String::new(),
            name: name.map(str::to_string),
            path: path.map(str::to_string),
            query: query.map(str::to_string),
        }
    }

    #[test]
    fn mcp_fetch_running_is_reading_course_with_page_id() {
        let result = activity(vec![
            request(),
            running(
                "f1",
                FETCH_TOOL,
                json!({"id": format!("native-editor://page/{PAGE}")}),
            ),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::ReadingCourse);
        assert_eq!(result.page_id.as_deref(), Some(PAGE));
        assert!(result.is_running);
        assert_eq!(result.subject, None);
        assert_eq!(result.step_count, 1);
        assert_eq!(result.course_pages_read, 1);
    }

    #[test]
    fn fetch_self_is_reading_outline() {
        let result = activity(vec![
            request(),
            running("f1", FETCH_TOOL, json!({"id": "self"})),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::ReadingCourseOutline);
        assert_eq!(result.page_id, None);
        assert_eq!(result.course_pages_read, 0);
    }

    #[test]
    fn fetch_after_completed_write_is_verifying() {
        let write = json!({"page_id": PAGE, "command": "replace_content", "new_str": "# Light"});
        let result = activity(vec![
            request(),
            done("f1", FETCH_TOOL, json!({"id": PAGE})),
            done("w1", UPDATE_PAGE_TOOL, write),
            running("f2", FETCH_TOOL, json!({"id": PAGE})),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::VerifyingCoursePage);
        assert_eq!(result.page_id.as_deref(), Some(PAGE));
        assert_eq!(result.course_pages_written, 1);

        // A fetch of another page after the write is still a read, and a
        // fetch that happened before the write never turns into a check.
        let result = activity(vec![
            request(),
            done(
                "w1",
                UPDATE_PAGE_TOOL,
                json!({"page_id": PAGE, "command": "update_content"}),
            ),
            running("f2", FETCH_TOOL, json!({"id": OTHER_PAGE})),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::ReadingCourse);
        let result = activity(vec![
            request(),
            running("f1", FETCH_TOOL, json!({"id": PAGE})),
            mcp_item(
                "w1",
                UPDATE_PAGE_TOOL,
                AppOperationStatus::InProgress,
                json!({"page_id": PAGE, "command": "replace_content"}),
                None,
            ),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::WritingCoursePage);
        assert_eq!(
            result.course_pages_written, 0,
            "a running write is not saved yet"
        );
    }

    #[test]
    fn completed_tool_with_nothing_newer_is_thinking() {
        let result = activity(vec![
            request(),
            done("f1", FETCH_TOOL, json!({"id": PAGE})),
            done("f2", FETCH_TOOL, json!({"id": OTHER_PAGE})),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::Thinking);
        assert_eq!(result.subject, None);
        assert_eq!(result.page_id, None);
        assert!(!result.is_running);
        assert_eq!(result.course_pages_read, 2);

        // A parallel call that is still running wins over the finished one.
        let result = activity(vec![
            request(),
            running("s1", SEARCH_TOOL, json!({"query": "Calvin cycle"})),
            done("f2", FETCH_TOOL, json!({"id": OTHER_PAGE})),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::SearchingCourse);
        assert!(result.is_running);
    }

    #[test]
    fn search_subject_is_query() {
        let result = activity(vec![
            request(),
            running(
                "s1",
                SEARCH_TOOL,
                json!({"query": "  absorption\n spectrum ", "limit": 10}),
            ),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::SearchingCourse);
        assert_eq!(result.subject.as_deref(), Some("absorption spectrum"));
    }

    #[test]
    fn update_page_commands_map_to_write_details_organize() {
        let kind =
            |arguments: Value| activity(vec![request(), running("w", UPDATE_PAGE_TOOL, arguments)]);
        let write = kind(json!({
            "page_id": format!("native-editor://page/{PAGE}"),
            "command": "replace_content",
            "properties": {"title": "Light Reactions", "generation_status": "generated"},
        }));
        assert_eq!(write.kind, AppTurnActivityKind::WritingCoursePage);
        assert_eq!(write.subject.as_deref(), Some("Light Reactions"));
        assert_eq!(write.page_id.as_deref(), Some(PAGE));
        assert!(write.is_running);
        assert_eq!(
            kind(json!({"page_id": PAGE, "command": "update_properties", "properties": {"title": "Renamed"}})).kind,
            AppTurnActivityKind::UpdatingCourseDetails
        );
        assert_eq!(
            kind(json!({"page_id": PAGE, "command": "trash"})).kind,
            AppTurnActivityKind::OrganizingCourse
        );
        assert_eq!(
            kind(json!({"page_id": PAGE, "command": "update_properties", "in_trash": true})).kind,
            AppTurnActivityKind::OrganizingCourse
        );
        for organizing in [MOVE_PAGES_TOOL, DUPLICATE_PAGE_TOOL] {
            assert_eq!(
                activity(vec![
                    request(),
                    running("m", organizing, json!({"page_id": PAGE}))
                ])
                .kind,
                AppTurnActivityKind::OrganizingCourse
            );
        }
        assert_eq!(
            activity(vec![
                request(),
                running("a", ASYNC_TASK_TOOL, json!({"task_id": "task-1"}))
            ])
            .kind,
            AppTurnActivityKind::SavingCourseChanges
        );
    }

    #[test]
    fn truncated_update_page_arguments_degrade_to_no_subject() {
        // Hydration cuts arguments at 4 KiB mid-`new_str`; keys keep the
        // order the model wrote them in.
        let arguments = format!(
            "{{\n  \"page_id\": \"{PAGE}\",\n  \"command\": \"replace_content\",\n  \"new_str\": {},\n  \"properties\": {{\"title\": \"Light Reactions\"}}\n}}",
            Value::String("Light reactions turn \"photons\" into ATP. ".repeat(200)),
        );
        let truncated = format!("{}... [truncated on mobile]", &arguments[..4000]);
        let result = activity(vec![
            request(),
            mcp_item_with_raw_arguments(
                "w1",
                UPDATE_PAGE_TOOL,
                AppOperationStatus::InProgress,
                truncated.clone(),
                None,
            ),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::WritingCoursePage);
        assert_eq!(result.subject, None);
        assert_eq!(
            result.page_id.as_deref(),
            Some(PAGE),
            "page_id before the cut survives"
        );

        // Keys after the cut are lost; the write still counts once saved.
        let reordered = format!(
            "{{\"new_str\": \"{}\", \"page_id\": \"{PAGE}\", \"command\": \"trash\"}}",
            "x".repeat(5000)
        );
        let result = activity(vec![
            request(),
            mcp_item_with_raw_arguments(
                "w2",
                UPDATE_PAGE_TOOL,
                AppOperationStatus::Completed,
                format!("{}... [truncated on mobile]", &reordered[..4000]),
                None,
            ),
            mcp_item_with_raw_arguments(
                "w3",
                UPDATE_PAGE_TOOL,
                AppOperationStatus::InProgress,
                "{\"page_id\": \"unterminated".to_string(),
                None,
            ),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::WritingCoursePage);
        assert_eq!(result.subject, None);
        assert_eq!(result.page_id, None);
        assert_eq!(result.course_pages_written, 1);
    }

    #[test]
    fn page_title_resolved_from_search_and_fetch_results() {
        let search = mcp_item(
            "s1",
            SEARCH_TOOL,
            AppOperationStatus::Completed,
            json!({"query": "chlorophyll"}),
            Some(json!({
                "object": "list",
                "results": [
                    {"object": "page", "id": OTHER_PAGE, "title": "Light vs. dark reactions"},
                    {"object": "page", "id": PAGE, "title": "Chlorophyll basics",
                     "url": format!("native-editor://page/{PAGE}")},
                ],
            })),
        );
        let result = activity(vec![
            request(),
            search,
            running("f1", FETCH_TOOL, json!({"id": PAGE})),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::ReadingCourse);
        assert_eq!(result.subject.as_deref(), Some("Chlorophyll basics"));

        // A finished fetch of the page names it for the later check, even
        // when the result was cut mid-Markdown.
        let mut cut = format!(
            "{{\n  \"object\": \"page_markdown\",\n  \"id\": \"{PAGE}\",\n  \"title\": \"Light Reactions\",\n  \"markdown\": {}\n}}",
            Value::String("\"quoted\" body ".repeat(20)),
        );
        cut.truncate(cut.len() - 40);
        cut.push_str("\n[output truncated on mobile]\n");
        let mut fetch = mcp_item(
            "f1",
            FETCH_TOOL,
            AppOperationStatus::Completed,
            json!({"id": PAGE}),
            None,
        );
        if let HydratedConversationItemContent::McpToolCall(data) = &mut fetch.content {
            data.structured_content_json = Some(cut);
        }
        let result = activity(vec![
            request(),
            fetch,
            done(
                "w1",
                UPDATE_PAGE_TOOL,
                json!({"page_id": PAGE, "command": "update_content"}),
            ),
            running("f2", FETCH_TOOL, json!({"id": PAGE})),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::VerifyingCoursePage);
        assert_eq!(result.subject.as_deref(), Some("Light Reactions"));

        // Results from the previous request are out of scope.
        let result = activity(vec![
            user_item("u0", "Earlier question", Some("t0")),
            mcp_item(
                "s0",
                SEARCH_TOOL,
                AppOperationStatus::Completed,
                json!({"query": "chlorophyll"}),
                Some(json!({"results": [{"id": PAGE, "title": "Chlorophyll basics"}]})),
            ),
            request(),
            running("f1", FETCH_TOOL, json!({"id": PAGE})),
        ]);
        assert_eq!(result.subject, None);
    }

    #[test]
    fn page_title_skips_results_that_only_name_the_page_as_parent() {
        let chapter_fetch = mcp_item(
            "f1",
            FETCH_TOOL,
            AppOperationStatus::Completed,
            json!({"id": PAGE}),
            Some(json!({"object": "page_markdown", "id": PAGE,
                "title": "Light Reactions", "markdown": "# Light Reactions"})),
        );
        let child_search = mcp_item(
            "s1",
            SEARCH_TOOL,
            AppOperationStatus::Completed,
            json!({"query": "photosystem"}),
            Some(json!({
                "object": "list",
                "results": [{
                    "object": "page", "id": OTHER_PAGE, "title": "Photosystem II",
                    "url": format!("native-editor://page/{OTHER_PAGE}"),
                    "parent": {"type": "page_id", "page_id": PAGE},
                }],
            })),
        );
        let result = activity(vec![
            request(),
            chapter_fetch,
            child_search,
            running("f2", FETCH_TOOL, json!({"id": PAGE})),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::ReadingCourse);
        assert_eq!(result.subject.as_deref(), Some("Light Reactions"));
    }

    #[test]
    fn lists_page_id_matches_entry_ids_not_parents() {
        let compact = format!(r#"{{"results":[{{"id":"{PAGE}","title":"A"}}]}}"#);
        assert!(lists_page_id(&compact, PAGE));
        let pretty = format!("{{\n  \"id\": \"native-editor://page/{PAGE}\"\n}}");
        assert!(lists_page_id(&pretty, PAGE));
        let escaped = serde_json::to_string(&json!({"text": compact})).unwrap();
        assert!(lists_page_id(&escaped, PAGE));
        let parent_only = format!(
            r#"{{"results":[{{"id":"{OTHER_PAGE}","url":"native-editor://page/{OTHER_PAGE}","parent":{{"type":"page_id","page_id":"{PAGE}"}}}}]}}"#
        );
        assert!(!lists_page_id(&parent_only, PAGE));
    }

    #[test]
    fn create_pages_counts_units_and_first_title() {
        let result = activity(vec![
            request(),
            running(
                "c1",
                CREATE_PAGES_TOOL,
                json!({"pages": [
                    {"properties": {"title": "Photosystem II"}},
                    {"properties": {"title": "Photosystem I"}},
                    {"properties": {"title": "ATP synthase"}},
                ]}),
            ),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::AddingCoursePages);
        assert_eq!(result.unit_count, 3);
        assert_eq!(result.subject.as_deref(), Some("Photosystem II"));

        // A page created earlier names a later fetch through its result.
        let created = mcp_item(
            "c1",
            CREATE_PAGES_TOOL,
            AppOperationStatus::Completed,
            json!({"pages": [{"properties": {"title": "Photosystem II"}}]}),
            Some(json!({"results": [{"id": PAGE, "title": "Photosystem II"}]})),
        );
        let result = activity(vec![
            request(),
            created,
            running("f1", FETCH_TOOL, json!({"id": PAGE})),
        ]);
        assert_eq!(result.subject.as_deref(), Some("Photosystem II"));
    }

    #[test]
    fn direct_namespace_and_dynamic_tools_classify_like_mcp() {
        let arguments = Some(json!({"query": "Calvin cycle"}).to_string());
        let dynamic = tool_item(
            "d1",
            SEARCH_TOOL,
            AppOperationStatus::InProgress,
            arguments.clone(),
            None,
            None,
            Some("t1"),
        );
        let direct = tool_item(
            "d2",
            "mcp__learnfold_course__native-editor-search",
            AppOperationStatus::InProgress,
            arguments,
            None,
            None,
            Some("t1"),
        );
        for item in [dynamic, direct] {
            let result = activity(vec![request(), item]);
            assert_eq!(result.kind, AppTurnActivityKind::SearchingCourse);
            assert_eq!(result.subject.as_deref(), Some("Calvin cycle"));
        }

        let bash = tool_item(
            "b1",
            COURSE_BASH_TOOL,
            AppOperationStatus::InProgress,
            Some(json!({"script": "cat /workspace/notes.md"}).to_string()),
            None,
            None,
            Some("t1"),
        );
        let result = activity(vec![request(), bash]);
        assert_eq!(result.kind, AppTurnActivityKind::CheckingCourseFiles);
        assert_eq!(result.subject, None);

        let lesson = tool_item(
            "g1",
            GENERATE_LESSON_TOOL,
            AppOperationStatus::Completed,
            Some(json!({"explanation": "…"}).to_string()),
            None,
            Some(true),
            Some("t1"),
        );
        let result = activity(vec![request(), lesson]);
        assert_eq!(result.kind, AppTurnActivityKind::Thinking);
        assert_eq!(result.course_pages_written, 1);

        let mut plan = tool_item(
            "p1",
            PRESENT_PLAN_TOOL,
            AppOperationStatus::InProgress,
            None,
            None,
            None,
            Some("t1"),
        );
        if let HydratedConversationItemContent::DynamicToolCall(data) = &mut plan.content {
            data.namespace = Some("learnfold_course".to_string());
        }
        assert_eq!(
            activity(vec![request(), plan]).kind,
            AppTurnActivityKind::PlanningCourse
        );
    }

    #[test]
    fn hermes_envelopes_classify_and_scope_spans_tool_result_turns() {
        let wrapped =
            "Learnfold remote native-tool protocol:\n- rules\n\nLearner message:\nWrite it";
        let call = |name: &str, arguments: Value| {
            json!({"learnfold_tool_call": {"name": name, "arguments": arguments}}).to_string()
        };
        let result_envelope = |name: &str| {
            format!(
                "{{\"learnfold_tool_result\":{{\"name\":\"{name}\",\"success\":true}}}}\n\nContinue the course task."
            )
        };
        let mut hermes = thread(vec![
            user_item("u1", wrapped, Some("t1")),
            assistant_item("a1", &call(FETCH_TOOL, json!({"id": PAGE})), Some("t1")),
            user_item("u2", &result_envelope(FETCH_TOOL), Some("t2")),
            assistant_item(
                "a2",
                &call(
                    UPDATE_PAGE_TOOL,
                    json!({"page_id": PAGE, "command": "replace_content", "new_str": "# Done"}),
                ),
                Some("t2"),
            ),
        ]);
        hermes.agent_runtime_kind = "hermes".into();
        hermes.active_turn_id = Some("t2".into());
        let result = current_turn_activity(&hermes).expect("activity");
        assert_eq!(result.kind, AppTurnActivityKind::WritingCoursePage);
        assert!(result.is_running, "no result envelope yet");
        assert_eq!(
            result.course_pages_read, 1,
            "the fetch from turn t1 still counts"
        );

        // The write's result arrives as turn t3; until the server echoes it,
        // the bound overlay keeps the request open instead of restarting.
        hermes.active_turn_id = Some("t3".into());
        let mut overlay = user_item(
            "local-user-message:1",
            &result_envelope(UPDATE_PAGE_TOOL),
            Some("t3"),
        );
        overlay.id = "local-user-message:1".into();
        hermes.local_overlay_items.push(overlay);
        let result = current_turn_activity(&hermes).expect("activity");
        assert_eq!(result.kind, AppTurnActivityKind::WritingCoursePage);

        hermes.items.push(user_item(
            "u3",
            &result_envelope(UPDATE_PAGE_TOOL),
            Some("t3"),
        ));
        hermes.items.push(assistant_item(
            "a3",
            &call(FETCH_TOOL, json!({"id": PAGE})),
            Some("t3"),
        ));
        let result = current_turn_activity(&hermes).expect("activity");
        assert_eq!(result.kind, AppTurnActivityKind::VerifyingCoursePage);
        assert_eq!(result.course_pages_written, 1);

        // A half-streamed envelope is neither a reply nor a tool yet.
        hermes
            .items
            .push(user_item("u4", &result_envelope(FETCH_TOOL), Some("t4")));
        hermes
            .items
            .push(assistant_item("a4", "{\"learnfold_tool_ca", Some("t4")));
        hermes.active_turn_id = Some("t4".into());
        assert_eq!(
            current_turn_activity(&hermes).expect("activity").kind,
            AppTurnActivityKind::Thinking
        );
    }

    #[test]
    fn scope_excludes_previous_request() {
        let result = activity(vec![
            user_item("u0", "Earlier", Some("t0")),
            done(
                "w0",
                UPDATE_PAGE_TOOL,
                json!({"page_id": PAGE, "command": "replace_content"}),
            ),
            running("f0", FETCH_TOOL, json!({"id": OTHER_PAGE})),
            assistant_item("a0", "Done.", Some("t0")),
            user_item("u1", "Next lesson", Some("t1")),
            running("f1", FETCH_TOOL, json!({"id": PAGE})),
        ]);
        assert_eq!(
            result.kind,
            AppTurnActivityKind::ReadingCourse,
            "the old write is out of scope"
        );
        assert_eq!(result.course_pages_read, 1);
        assert_eq!(result.course_pages_written, 0);
        assert_eq!(result.step_count, 1);
    }

    #[test]
    fn active_turn_without_items_is_starting() {
        let mut idle = thread(vec![
            user_item("u0", "Earlier", Some("t0")),
            assistant_item("a0", "Done.", Some("t0")),
        ]);
        assert_eq!(
            current_turn_activity(&idle).expect("activity").kind,
            AppTurnActivityKind::Responding
        );
        idle.active_turn_id = Some("t1".into());
        assert_eq!(
            current_turn_activity(&idle),
            Some(empty_activity(AppTurnActivityKind::Starting))
        );

        idle.items.push(user_item("u1", "Next", Some("t1")));
        assert_eq!(
            current_turn_activity(&idle).expect("activity").kind,
            AppTurnActivityKind::Starting
        );

        let empty = thread(Vec::new());
        assert_eq!(current_turn_activity(&empty), None);
    }

    #[test]
    fn reasoning_headline_sanitized_and_tool_names_dropped() {
        let result = activity(vec![
            request(),
            done("f1", FETCH_TOOL, json!({"id": PAGE})),
            reasoning(
                "r1",
                vec![
                    "**Reading the draft**\n\nLooking at it.",
                    "**Tracing the `token` refresh   path**\n\nThe refresh runs twice.",
                ],
                Vec::new(),
            ),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::Thinking);
        assert_eq!(
            result.subject.as_deref(),
            Some("Tracing the token refresh path")
        );

        // Live summary deltas land in `content` until the item completes.
        let streaming = activity(vec![
            request(),
            reasoning(
                "r1",
                Vec::new(),
                vec!["**Comparing photosystems**\n\nPSII first"],
            ),
        ]);
        assert_eq!(streaming.subject.as_deref(), Some("Comparing photosystems"));

        let leaky = activity(vec![
            request(),
            reasoning(
                "r1",
                vec!["**Calling native-editor-update-page next**"],
                Vec::new(),
            ),
        ]);
        assert_eq!(leaky.kind, AppTurnActivityKind::Thinking);
        assert_eq!(leaky.subject, None);

        let words = "word ".repeat(30);
        let long = activity(vec![
            request(),
            reasoning("r1", vec![words.as_str()], Vec::new()),
        ]);
        let subject = long.subject.expect("subject");
        assert!(subject.ends_with('…'));
        assert_eq!(subject.chars().count(), SUBJECT_CHARACTER_LIMIT);
    }

    #[test]
    fn assistant_with_plan_fence_is_planning() {
        let plan = "Here is the plan.\n\n```learnfold-plan\n# Photosynthesis\n";
        assert_eq!(
            activity(vec![request(), assistant_item("a1", plan, Some("t1"))]).kind,
            AppTurnActivityKind::PlanningCourse
        );
        assert_eq!(
            activity(vec![request(), assistant_item("a1", "", Some("t1"))]).kind,
            AppTurnActivityKind::Responding
        );
    }

    #[test]
    fn command_strips_cd_prefix_and_exploration_reads_files() {
        let result = activity(vec![
            request(),
            command(
                "c1",
                "cd \"/Volumes/Codex Storage/repo\" && cd shared && cargo test -p codex-mobile-client",
                AppOperationStatus::InProgress,
                vec![action(HydratedCommandActionKind::Unknown, None, None, None)],
            ),
        ]);
        assert_eq!(result.kind, AppTurnActivityKind::RunningCommand);
        assert_eq!(
            result.subject.as_deref(),
            Some("cargo test -p codex-mobile-client")
        );
        assert_eq!(strip_cd_prefix("cd /repo"), "cd /repo");
        assert_eq!(strip_cd_prefix("cd /repo; make"), "make");

        let read = activity(vec![
            request(),
            command(
                "c2",
                "sed -n 1,80p apps/ios/Sources/Litter/Models/AppModel.swift",
                AppOperationStatus::InProgress,
                vec![action(
                    HydratedCommandActionKind::Read,
                    Some("AppModel.swift"),
                    Some("apps/ios/Sources/Litter/Models/AppModel.swift"),
                    None,
                )],
            ),
        ]);
        assert_eq!(read.kind, AppTurnActivityKind::ReadingFiles);
        assert_eq!(read.subject.as_deref(), Some("AppModel.swift"));
        assert_eq!(read.unit_count, 1);

        let search = activity(vec![
            request(),
            command(
                "c3",
                "rg -n \"refreshToken\" src",
                AppOperationStatus::InProgress,
                vec![action(
                    HydratedCommandActionKind::Search,
                    None,
                    Some("src"),
                    Some("refreshToken"),
                )],
            ),
        ]);
        assert_eq!(search.kind, AppTurnActivityKind::SearchingFiles);
        assert_eq!(search.subject.as_deref(), Some("refreshToken"));
    }

    #[test]
    fn file_change_basename_and_unit_count() {
        let change = |path: &str| HydratedFileChangeEntryData {
            path: path.to_string(),
            kind: "update".to_string(),
            diff: String::new(),
            additions: 1,
            deletions: 0,
        };
        let item = HydratedConversationItem {
            id: "e1".to_string(),
            content: HydratedConversationItemContent::FileChange(HydratedFileChangeData {
                status: AppOperationStatus::InProgress,
                changes: vec![
                    change("/Users/me/apps/ios/Sources/Litter/Models/AppModel.swift"),
                    change("/Users/me/apps/ios/Sources/Litter/Models/AppState.swift"),
                    change("/Users/me/README.md"),
                ],
            }),
            source_turn_id: Some("t1".to_string()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        };
        let result = activity(vec![request(), item]);
        assert_eq!(result.kind, AppTurnActivityKind::EditingFiles);
        assert_eq!(result.subject.as_deref(), Some("AppModel.swift"));
        assert_eq!(result.unit_count, 3);
        assert!(result.is_running);
    }

    #[test]
    fn unknown_mcp_humanized_with_server() {
        let mut item = running("x1", "create_issue", json!({"title": "Flaky login"}));
        if let HydratedConversationItemContent::McpToolCall(data) = &mut item.content {
            data.server = "linear".to_string();
        }
        let result = activity(vec![request(), item]);
        assert_eq!(result.kind, AppTurnActivityKind::UsingTool);
        assert_eq!(result.subject.as_deref(), Some("Linear · create issue"));

        let dynamic = tool_item(
            "x2",
            "mcp__github__createPullRequest",
            AppOperationStatus::InProgress,
            None,
            None,
            None,
            Some("t1"),
        );
        assert_eq!(
            activity(vec![request(), dynamic]).subject.as_deref(),
            Some("Github · create pull request")
        );
    }

    #[test]
    fn counters_count_distinct_reads_and_successful_writes() {
        let mut failed_write = done(
            "w2",
            UPDATE_PAGE_TOOL,
            json!({"page_id": OTHER_PAGE, "command": "replace_content"}),
        );
        if let HydratedConversationItemContent::McpToolCall(data) = &mut failed_write.content {
            data.error_message = Some("revision mismatch".to_string());
        }
        let result = activity(vec![
            request(),
            done("o1", FETCH_TOOL, json!({"id": "self"})),
            done("f1", FETCH_TOOL, json!({"id": PAGE})),
            done(
                "f2",
                FETCH_TOOL,
                json!({"id": format!("native-editor://page/{PAGE}")}),
            ),
            mcp_item(
                "f3",
                FETCH_TOOL,
                AppOperationStatus::Failed,
                json!({"id": "missing-page"}),
                None,
            ),
            done("f4", FETCH_TOOL, json!({"id": OTHER_PAGE})),
            done(
                "w1",
                UPDATE_PAGE_TOOL,
                json!({"page_id": PAGE, "command": "replace_content"}),
            ),
            done(
                "w1b",
                UPDATE_PAGE_TOOL,
                json!({"page_id": PAGE, "command": "update_content"}),
            ),
            failed_write,
            done(
                "p1",
                UPDATE_PAGE_TOOL,
                json!({"page_id": OTHER_PAGE, "command": "update_properties"}),
            ),
            running("f5", FETCH_TOOL, json!({"id": PAGE})),
        ]);
        assert_eq!(result.course_pages_read, 2);
        assert_eq!(result.course_pages_written, 1);
        assert_eq!(result.kind, AppTurnActivityKind::VerifyingCoursePage);
        assert_eq!(result.step_count, 1);
    }

    #[test]
    fn subject_never_json_ids_or_wire_tool_names() {
        let hostile = [
            json!({"id": PAGE, "query": PAGE, "page_id": PAGE, "command": "replace_content",
                   "properties": {"title": "{\"title\":\"x\"}"},
                   "pages": [{"properties": {"title": "[1, 2]"}}]}),
            json!({"id": format!("native-editor://page/{PAGE}"), "query": "native-editor-fetch self",
                   "page_id": PAGE, "properties": {"title": "learnfold_course notes"},
                   "pages": [{"properties": {"title": "mcp__learnfold_course__native-editor-fetch"}}]}),
            json!({"id": "self", "query": "{\"q\": 1}", "task_id": PAGE, "page_ids": [PAGE]}),
        ];
        for tool in normalize::EDITOR_TOOLS {
            for arguments in &hostile {
                for status in [
                    AppOperationStatus::InProgress,
                    AppOperationStatus::Completed,
                ] {
                    let items = vec![
                        request(),
                        mcp_item("x", tool, status, arguments.clone(), None),
                    ];
                    let result = activity(items);
                    let Some(subject) = result.subject.as_deref() else {
                        continue;
                    };
                    assert!(
                        !subject.contains(PAGE)
                            && !subject.contains('{')
                            && !subject.contains('[')
                            && !subject.contains("native-editor")
                            && !subject.contains("learnfold_")
                            && !subject.contains("mcp__"),
                        "{tool} leaked {subject:?}"
                    );
                }
            }
        }
        assert_eq!(clean_subject("  [\"a\"] "), None);
        assert_eq!(
            clean_subject("Using **bold** `code`").as_deref(),
            Some("Using bold code")
        );
    }
}
