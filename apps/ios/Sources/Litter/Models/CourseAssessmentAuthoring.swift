import Foundation

/// The authored Markdown contract shared by course generation prompts and native lesson tools.
enum CourseAssessmentAuthoring {
    static let fenceLanguage = "learnfold-assessment"

    static let authoringInstructions = """
    Make lessons comfortable to read on a phone. Use real Markdown section headings: \
    ## Explanation, ## Worked example (or ## Scenario), and ## Exercise. Write short \
    two- or three-sentence paragraphs separated by a blank line. Prefer one idea per paragraph \
    and concise lists for genuinely parallel steps. Do not merge the scenario or exercise into \
    a long paragraph introduced only by a bold label. When a structured lesson tool supplies \
    these headings, return each field's section body without repeating its heading. Preserve \
    runnable-code example headings and fences required by that tool.

    Put one optional understanding check in the Exercise section. Default to one quick \
    multiple-choice question; choose free text when explaining a key idea is more useful, or \
    discussion when guided questions will help the learner reason through the page. Checks \
    never gate the next lesson. Ground every question, correct answer, explanation, and rubric \
    in what this page teaches; do not require unstated facts or invent evidence.

    Author each check as a fenced JSON object tagged learnfold-assessment. This reserved fence \
    becomes a native exercise card, rather than visible code. Use version: 1, a stable \
    lowercase slug id unique on this page, kind, and prompt; title is optional. Keep the id \
    unchanged when revising the same check. Do not use the chat's learnfold-question format \
    for page exercises. Use valid JSON, with no comments or trailing commas.

    For multiple_choice, supply two to five options with distinct stable slug ids and distinct \
    text. Exactly one option is correct. answer.option_id must identify that option, and \
    answer.explanation should briefly explain why using the page. Keep the answer key only \
    inside the reserved fence, never in the surrounding visible prose. For free_text, supply \
    a nonempty rubric array of short key ideas; accept equivalent wording rather than exact \
    phrases. For discussion, opening_prompt optionally provides the tutor's first question, \
    and rubric optionally lists key ideas to explore. Ask one clear opening question without \
    answering it for the learner. Author definitions only: do not grade imaginary responses \
    or produce learnfold-review grading fences during course generation.

    Exact multiple-choice example, for a page explaining oxygen's role in electron transport:
    ```learnfold-assessment
    {"version":1,"id":"oxygen-loss","kind":"multiple_choice","title":"Check your understanding","prompt":"When oxygen delivery stops, which process described on this page fails first?","options":[{"id":"ion-pumping","text":"ATP-dependent ion pumping"},{"id":"dna-storage","text":"DNA storage"},{"id":"inheritance","text":"Inherited genetic information"}],"answer":{"option_id":"ion-pumping","explanation":"The page explains that oxygen loss stalls electron transport and lowers ATP production, so ATP-dependent pumps fail."}}
    ```

    Exact free-text example for the same page:
    ```learnfold-assessment
    {"version":1,"id":"oxygen-to-atp","kind":"free_text","prompt":"Explain how oxygen loss reduces ATP production using the sequence taught on this page.","rubric":["Oxygen accepts electrons at the end of the electron-transport chain.","Without oxygen, electron transport stalls and the proton gradient collapses.","ATP synthase depends on proton flow, so ATP production falls."]}
    ```

    Exact discussion example for the same page:
    ```learnfold-assessment
    {"version":1,"id":"cell-injury-discussion","kind":"discussion","title":"Think it through together","prompt":"Discuss how an interrupted energy supply can injure a cell.","opening_prompt":"If electron transport stalls, what happens to the proton gradient, and why?","rubric":["Connect loss of the proton gradient to reduced ATP production.","Connect pump failure to water entering cells and tissue injury."]}
    ```
    These examples illustrate the format; adapt their subject matter to the actual page.
    """

    static let exerciseSchemaDescription = """
    One optional understanding check as a complete ```learnfold-assessment fenced JSON object, \
    with version 1, stable slug id, kind, prompt, and optional title. Default kind is \
    multiple_choice: options has 2–5 distinct {id,text} objects and answer has option_id matching \
    one option plus explanation. free_text has a nonempty rubric string array. discussion \
    may have opening_prompt and rubric. Ground the check and key ideas in this lesson. Keep \
    the answer key inside the fence. Do not repeat the Exercise heading or grade a response.
    """
}
