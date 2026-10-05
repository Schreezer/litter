import { describe, expect, it } from "vitest"

import {
  ASSESSMENT_FENCE,
  COURSE_AGENT_PROMPT,
  COURSE_ASSESSMENT_AUTHORING_PROMPT,
  COURSE_DISCUSSION_PROMPT,
  COURSE_EXPLORATION_PROMPT,
  QUESTION_FENCE,
} from "../src/course-prompt"

describe("course prompt", () => {
  it("teaches the multiple-choice fence the iOS chat parses", () => {
    expect(QUESTION_FENCE).toBe("learnfold-question")
    expect(COURSE_AGENT_PROMPT).toContain(`\`\`\`${QUESTION_FENCE}\n`)
    expect(COURSE_AGENT_PROMPT).toContain("For a bounded-answer question")
    expect(COURSE_AGENT_PROMPT).toContain("Ask at least one such fenced question")
    expect(COURSE_AGENT_PROMPT).toContain("genuinely distinct, non-overlapping answers")
    expect(COURSE_AGENT_PROMPT).toContain("not a tool call")
    expect(COURSE_AGENT_PROMPT).toContain("works in New Course and course-building chat")
  })

  it("asks assessment questions in separate turns, including the open-ended diagnostic", () => {
    expect(COURSE_AGENT_PROMPT).toContain("Ask only one assessment question in each reply")
    expect(COURSE_AGENT_PROMPT).toContain("wait for the learner's answer before asking another")
    expect(COURSE_AGENT_PROMPT).toContain("Never bundle questions in a numbered list")
    expect(COURSE_AGENT_PROMPT).toContain("Do not present bounded choices as plain-text numbered questions")
    expect(COURSE_AGENT_PROMPT).toContain("Ask that question in its own reply, without a fence")
  })

  it("keeps the example block well formed", () => {
    const match = COURSE_AGENT_PROMPT.match(/```learnfold-question\n([\s\S]*?)\n```/)
    expect(match).not.toBeNull()
    const lines = match![1].split("\n")
    expect(lines[0]).toMatch(/\?$/)
    const options = lines.slice(1)
    expect(options.length).toBeGreaterThanOrEqual(2)
    expect(options.length).toBeLessThanOrEqual(5)
    for (const option of options) expect(option).toMatch(/^- \S/)
    expect(new Set(options.map((option) => option.toLowerCase())).size).toBe(options.length)
  })

  it("uses the phone-owned shell and saves only the requested lesson atomically", () => {
    expect(COURSE_AGENT_PROMPT).toContain("the phone creates the root, learner context pages")
    expect(COURSE_AGENT_PROMPT).toContain("write only the exact existing page named by Learnfold")
    expect(COURSE_AGENT_PROMPT).toContain("properties.generation_status = generated in the same native-editor-update-page call")
    expect(COURSE_AGENT_PROMPT).toContain("A chat reply does not generate a lesson")
    expect(COURSE_AGENT_PROMPT).toContain("course shell must be repaired by Learnfold")
    expect(COURSE_AGENT_PROMPT).not.toContain("create the complete ordered hierarchy, and write Chapter 1")
  })

  it("authors readable sections and optional page-grounded checks without revealing keys", () => {
    expect(COURSE_AGENT_PROMPT).toContain(COURSE_ASSESSMENT_AUTHORING_PROMPT)
    for (const heading of ["## Explanation", "## Worked example", "## Scenario", "## Exercise"]) {
      expect(COURSE_ASSESSMENT_AUTHORING_PROMPT).toContain(heading)
    }
    expect(COURSE_ASSESSMENT_AUTHORING_PROMPT).toContain("paragraphs separated by a blank line")
    expect(COURSE_ASSESSMENT_AUTHORING_PROMPT).toContain("Checks never gate the next lesson")
    expect(COURSE_ASSESSMENT_AUTHORING_PROMPT).toContain("in what this page teaches")
    expect(COURSE_ASSESSMENT_AUTHORING_PROMPT).toContain("never in the surrounding visible prose")
    expect(COURSE_ASSESSMENT_AUTHORING_PROMPT).toContain("Keep the id unchanged")
    expect(COURSE_ASSESSMENT_AUTHORING_PROMPT).toContain("do not grade imaginary responses")
    expect(COURSE_ASSESSMENT_AUTHORING_PROMPT).not.toContain("```learnfold-review")
  })

  it("gives exactly one valid native example for each exercise format", () => {
    expect(ASSESSMENT_FENCE).toBe("learnfold-assessment")
    expect(ASSESSMENT_FENCE).not.toBe(QUESTION_FENCE)
    const examples = [...COURSE_ASSESSMENT_AUTHORING_PROMPT.matchAll(/```learnfold-assessment\n([\s\S]*?)\n```/g)]
      .map((match) => JSON.parse(match[1]) as {
        version: number
        id: string
        kind: string
        prompt: string
        options?: { id: string; text: string }[]
        answer?: { option_id: string; explanation: string }
        rubric?: string[]
        opening_prompt?: string
      })
    expect(examples.map((example) => example.kind)).toEqual(["multiple_choice", "free_text", "discussion"])
    expect(new Set(examples.map((example) => example.id)).size).toBe(examples.length)
    for (const example of examples) {
      expect(example.version).toBe(1)
      expect(example.id).toMatch(/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
      expect(example.prompt.length).toBeGreaterThan(0)
    }

    const multipleChoice = examples[0]
    expect(multipleChoice.options!.length).toBeGreaterThanOrEqual(2)
    expect(multipleChoice.options!.length).toBeLessThanOrEqual(5)
    expect(new Set(multipleChoice.options!.map((option) => option.id)).size).toBe(multipleChoice.options!.length)
    expect(new Set(multipleChoice.options!.map((option) => option.text.toLowerCase())).size).toBe(multipleChoice.options!.length)
    expect(multipleChoice.options!.filter((option) => option.id === multipleChoice.answer!.option_id)).toHaveLength(1)
    expect(multipleChoice.answer!.explanation.length).toBeGreaterThan(0)

    expect(examples[1].rubric!.length).toBeGreaterThan(0)
    expect(examples[1].rubric!.every((criterion) => criterion.trim().length > 0)).toBe(true)
    expect(examples[2].opening_prompt).toMatch(/\?$/)
    expect(examples[2].rubric!.length).toBeGreaterThan(0)
  })

  it("treats the course as an open-ended map and forks explorations without limits", () => {
    expect(COURSE_AGENT_PROMPT).toContain(COURSE_EXPLORATION_PROMPT)
    expect(COURSE_EXPLORATION_PROMPT).toContain("The approved plan is only a suggested route")
    expect(COURSE_EXPLORATION_PROMPT).toContain("Never steer them back to the plan")
    expect(COURSE_EXPLORATION_PROMPT).toContain("course_role = explainer")
    expect(COURSE_EXPLORATION_PROMPT).toContain("Explorations may nest without limit")
  })

  it("keeps discussions from assessing or replanning the existing course", () => {
    expect(COURSE_DISCUSSION_PROMPT).toContain("Do not assess the learner's level")
    expect(COURSE_DISCUSSION_PROMPT).toContain("never propose, present, or revise a course plan")
    expect(COURSE_AGENT_PROMPT).not.toContain(COURSE_DISCUSSION_PROMPT)
  })
})
