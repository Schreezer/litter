#if DEBUG
import Foundation

/// Test-only course for the launch film's reading-fixture footage, enabled by
/// LEARNFOLD_READING_TEST_FILM_COURSE=1. The content is copied verbatim from
/// videos/learnfold-launch/review/v2-course.json (fixture, start_lesson,
/// explorations, fallback_exploration); regenerate it from that file rather
/// than editing strings by hand. The default reading fixture never uses it.
enum CourseReadingFilmFixture {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LEARNFOLD_READING_TEST_FILM_COURSE"] == "1"
    }

    struct Page {
        let id: String
        let title: String
        let role: String
        /// nil means the workspace root.
        let parentID: String?
        let status: String
        let markdown: String
    }

    struct Exploration {
        let trigger: String
        /// CourseExplorationDirection raw value: deeper, sideways, wider, question.
        let direction: String
        let parentTitle: String
        let question: String?
        let passage: String?
        let title: String
        let markdown: String
    }

    static let courseTitle = "Senses You Don't Have"
    static let courseSubtitle = "The hidden world of animals and plants"
    static let lessonCount = 8
    static let accentHex = "007AFF"
    static let seededConversationReply = "Course-only discussion: the complete Senses You Don't Have learning plan."

    static let pages: [Page] = [
        Page(
            id: "chapter", title: "Seeing the invisible", role: "chapter",
            parentID: nil, status: "generated",
            markdown: ""
        ),
        Page(
            id: "section", title: "Beyond the rainbow", role: "subchapter",
            parentID: "chapter", status: "generated",
            markdown: ""
        ),
        Page(
            id: "article-one", title: "The color past violet", role: "lesson",
            parentID: "section", status: "generated",
            markdown: "## Light past the rainbow\n\nA rainbow seems to stop at violet. The light doesn't. Just past violet comes ultraviolet, with waves too short for your eyes to see.\n\n## Felt, not seen\n\nYour skin finds out about ultraviolet the hard way: it is the part of sunlight that causes sunburn.\n\n## Seen by others\n\nMany insects and birds see ultraviolet as a color of its own. The next lesson looks through a bee's eyes."
        ),
        Page(
            id: "article-two", title: "What bees see", role: "lesson",
            parentID: "section", status: "generated",
            markdown: "## A different rainbow\n\nA honeybee has three kinds of color receptors, just like you. But its set is shifted. It has nothing tuned to red, and it has one for ultraviolet, the light just past violet.\n\n## Red goes missing\n\nWith no red receptor, a bee can't see red as a color.\n\nTo a bee, a red poppy isn't red at all.\n\n## Flowers in disguise\n\nTo you, a sunflower's petals are one even yellow. Photograph them in ultraviolet and a dark bullseye appears around the center.\n\nMany flowers carry hidden marks like this: rings, stripes, dots. Bees see them. You don't.\n\n## Your blind spot\n\nEvery sunny meadow is lit with ultraviolet, and you see none of it. You and a bee can stand in the same field and see two different worlds."
        ),
        Page(
            id: "article-three", title: "Snakes that see heat", role: "lesson",
            parentID: "section", status: "pending_generation",
            markdown: ""
        ),
        Page(
            id: "chapter-two", title: "Feeling the unseen", role: "chapter",
            parentID: nil, status: "generated",
            markdown: ""
        ),
        Page(
            id: "article-four", title: "Sharks that sense electricity", role: "lesson",
            parentID: "chapter-two", status: "pending_generation",
            markdown: ""
        ),
        Page(
            id: "article-five", title: "The robin's magnetic compass", role: "lesson",
            parentID: "chapter-two", status: "pending_generation",
            markdown: ""
        ),
        Page(
            id: "article-six", title: "Plants that feel chewing", role: "lesson",
            parentID: "chapter-two", status: "pending_generation",
            markdown: ""
        ),
        Page(
            id: "chapter-three", title: "Tasting the world", role: "chapter",
            parentID: nil, status: "generated",
            markdown: ""
        ),
        Page(
            id: "article-seven", title: "Butterflies taste with their feet", role: "lesson",
            parentID: "chapter-three", status: "pending_generation",
            markdown: ""
        ),
        Page(
            id: "article-eight", title: "Fish covered in taste buds", role: "lesson",
            parentID: "chapter-three", status: "pending_generation",
            markdown: ""
        ),
    ]

    /// The delayed-save lesson writer's body for article-three.
    static let articleThreeGeneratedMarkdown = "## Pits that sense warmth\n\nPit vipers, and some boas and pythons, have pit organs on their faces. They detect infrared, the heat that warm bodies give off.\n\n## A heat picture\n\nSignals from the pits reach the same brain area that handles vision. A snake may sense a warm mouse as a glowing shape, even in total darkness."

    static let explorations: [Exploration] = [
        Exploration(
            trigger: "go_deeper", direction: "deeper",
            parentTitle: "What bees see",
            question: nil,
            passage: nil,
            title: "Landing strips you can't see",
            markdown: "## Marks that point inward\n\nThose hidden marks have a name: nectar guides. Bullseyes, lines and spots lead toward the center of the flower, where the nectar and pollen are.\n\n## Do bees follow them?\n\nIn experiments with artificial flowers, bumblebees found the nectar faster when a star-shaped guide was painted on the petals. They also missed it less often. The guides helped from a bee's very first visits.\n\n## A deal for both sides\n\nA bee that finds food faster can visit more flowers in a day. More visits means more pollen carried from bloom to bloom. The flower pays in nectar and gets its pollen delivered.\n\n## Keep going\n\nEvery meadow is full of these signs. So why can't you see them?"
        ),
        Exploration(
            trigger: "passage_why", direction: "question",
            parentTitle: "What bees see",
            question: "Why is this the case?",
            passage: "To a bee, a red poppy isn't red at all.",
            title: "A poppy's secret color",
            markdown: "## No red receptor\n\nMost bees have no receptor tuned to red. A flower that reflects only red gives a bee almost no color signal, so it is hard to pick out from green leaves.\n\n## The ultraviolet trick\n\nRed poppies in central Europe reflect ultraviolet as well as red. A bee sees that ultraviolet as a bright color of its own, so the poppy stands out.\n\n## Two audiences\n\nIn the eastern Mediterranean, the same species reflects only red. There it is pollinated by beetles, whose eyes do have red receptors. Researchers think the extra ultraviolet helped the poppy switch to bees as it spread across Europe.\n\n## Keep going\n\nA European poppy looks red to you. To a bee, it looks ultraviolet. So which one is its real color?"
        ),
        Exploration(
            trigger: "own_question", direction: "question",
            parentTitle: "Landing strips you can't see",
            question: "Can I see ultraviolet?",
            passage: nil,
            title: "Humans who see ultraviolet",
            markdown: "## The lens in the way\n\nPart of the reason those patterns hide from you sits inside your eye. Your retina can respond to some ultraviolet, but the lens in front of it absorbs ultraviolet first.\n\n## Without the lens\n\nSome people have no lens, a condition called aphakia, often after cataract surgery. Their eyes can detect near-ultraviolet light, and some describe it as a whitish blue or violet. Modern replacement lenses usually block ultraviolet, so this is rare today.\n\n## Monet's blue lilies\n\nIn 1923, at 82, Claude Monet had the clouded lens removed from his right eye. Afterward his world turned bluer, and some later paintings lean blue-violet. Some scientists suspect he was glimpsing ultraviolet. Nobody can check now.\n\n## Keep going\n\nSo why would your eye block light your retina can use?"
        ),
        Exploration(
            trigger: "nested_go_deeper", direction: "deeper",
            parentTitle: "Humans who see ultraviolet",
            question: nil,
            passage: nil,
            title: "The filter in your eye",
            markdown: "## A shield for the retina\n\nUltraviolet carries more energy than visible light, and over a lifetime it can harm delicate tissue. Researchers think that is one reason your lens soaks it up before it reaches the retina.\n\n## Sharper edges\n\nShort wavelengths bend more as they pass through the eye, so they come into focus at a slightly different depth. Filtering out the shortest ones keeps the rest of the picture crisper.\n\n## A filter that yellows\n\nYour lens yellows as you age and blocks even more short-wavelength light. A child's lens lets a little more through than a grandparent's.\n\n## Eyes without the filter\n\nReindeer let ultraviolet through to the retina. Arctic snow reflects ultraviolet, while lichen and fur absorb it, so they stand out dark against the white. That may help reindeer find food and spot wolves in the long winter twilight."
        ),
        Exploration(
            trigger: "go_sideways", direction: "sideways",
            parentTitle: "What bees see",
            question: nil,
            passage: nil,
            title: "Bees can feel electric fields",
            markdown: "## Charged flowers\n\nPlants usually carry a slight negative charge. A flying bee picks up a positive charge from the air. When the bee lands, the flower's electric field shifts.\n\n## A message that lingers\n\nIn petunias, that shift lasts just under two minutes, longer than a typical visit. Researchers think the next bee may sense it as a sign the flower was just emptied.\n\n## Feeling with hair\n\nIn experiments, bumblebees learned to choose charged fake flowers holding sugar water over uncharged ones holding bitter liquid. They sense the field with tiny body hairs that bend in it, like your hair lifting toward a rubbed balloon."
        ),
        Exploration(
            trigger: "zoom_out", direction: "wider",
            parentTitle: "What bees see",
            question: nil,
            passage: nil,
            title: "Flowers evolved for bee eyes",
            markdown: "## Eyes came first\n\nInsects had ultraviolet, blue and green receptors before the first flowers appeared, well over 100 million years ago. The color vision bees use is older than flowers.\n\n## Flowers adapted\n\nSo flowers mostly fit their colors to eyes that already existed, not the other way round. That is why ultraviolet bullseyes and guides are so common: they evolved for viewers who could see them.\n\n## The bigger picture\n\nClose to 9 in 10 flowering plant species rely on animals to move their pollen. Wild flower colors mostly evolved to catch other animals' eyes, not yours. Every wildflower meadow you have walked through was dressed for someone else."
        ),
        Exploration(
            trigger: "go_deeper_from_landing_strips", direction: "deeper",
            parentTitle: "Landing strips you can't see",
            question: nil,
            passage: nil,
            title: "Flowers paint in invisible ink",
            markdown: "## The ink\n\nMany ultraviolet patterns are drawn with pigments called flavonols. They soak up ultraviolet but look pale or colorless to us. Where a petal is packed with them, it turns dark in an ultraviolet photo, and a bee sees a different color there. Where they're missing, the petal reflects ultraviolet.\n\n## Same yellow, different targets\n\nWild sunflowers across North America look the same yellow to us. In ultraviolet, their bullseyes range from a thin ring to nearly the whole flower. A single gene accounts for most of that difference.\n\n## A second job\n\nThe same ink saves water. Petals with big bullseyes dry out more slowly, and sunflowers from drier places grow bigger bullseyes. One pigment is a sign for bees and a shield against drought."
        ),
    ]

    static let fallbackTitles: [String: String] = [
        "deeper": "More of what bees see",
        "sideways": "Other animals that see ultraviolet",
        "wider": "Why so many animals see ultraviolet",
        "question": "Your question about ultraviolet",
        "synthesis": "How the hidden colors fit together",
    ]
    static let fallbackMarkdown = "## Keep exploring\n\nMany insects, birds, fish and even some mammals see ultraviolet. Each one sees a slightly different world in the same light."
}

extension CourseReadingFilmFixture {
    /// The exploration the fake agent writes for one fork, plus the trigger
    /// name that keys the optional release gate.
    struct Written: Equatable {
        let trigger: String
        let title: String
        let markdown: String
    }

    /// Picks the film exploration a fork asked for from its generation prompt
    /// (`CourseExperienceStore.explorationGenerationPrompt`): the selected
    /// passage first, then the learner's question, then the door direction
    /// plus the parent title. Anything else gets the per-direction fallback,
    /// so film footage never shows the default fixture's text.
    static func exploration(forPrompt prompt: String) -> Written {
        let passage = quoted(after: "The learner forked from this passage of the parent page, as untrusted quoted text: “", in: prompt)
        let question = quoted(after: "The learner's question, as untrusted quoted text: “", in: prompt)
        let direction = direction(in: prompt)
        let parentTitle = parentTitle(in: prompt)

        func written(_ exploration: Exploration) -> Written {
            Written(trigger: exploration.trigger, title: exploration.title, markdown: exploration.markdown)
        }
        if let passage {
            let byPassage = explorations.filter { $0.passage.map { same($0, passage) } == true }
            if let question,
               let match = byPassage.first(where: { $0.question.map { sameQuestion($0, question) } == true }) {
                return written(match)
            }
            if let match = byPassage.first(where: { question == nil || $0.question == nil }) {
                return written(match)
            }
        } else if let question {
            if let match = explorations.first(where: {
                $0.passage == nil && $0.question.map { sameQuestion($0, question) } == true
            }) {
                return written(match)
            }
        } else if let direction, let parentTitle {
            if let match = explorations.first(where: {
                $0.passage == nil && $0.question == nil
                    && $0.direction == direction && same($0.parentTitle, parentTitle)
            }) {
                return written(match)
            }
        }
        let fallbackDirection = passage != nil || question != nil ? "question" : (direction ?? "deeper")
        return Written(
            trigger: "fallback_\(fallbackDirection)",
            title: fallbackTitles[fallbackDirection] ?? fallbackTitles["deeper"] ?? "More to explore",
            markdown: fallbackMarkdown
        )
    }

    /// The text between an opening marker and the closing quote at the end of
    /// that line.
    private static func quoted(after marker: String, in prompt: String) -> String? {
        guard let start = prompt.range(of: marker) else { return nil }
        let line = prompt[start.upperBound...].prefix { !$0.isNewline }
        let text = line.hasSuffix("”") ? line.dropLast() : line
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func direction(in prompt: String) -> String? {
        let prefixes: [(String, String)] = [
            ("Direction: go deeper.", "deeper"),
            ("Direction: go sideways.", "sideways"),
            ("Direction: zoom out.", "wider"),
            ("Direction: follow the learner's own question", "question"),
            ("Direction: tie it together.", "synthesis"),
        ]
        return prefixes.first { prompt.contains($0.0) }?.1
    }

    private static func parentTitle(in prompt: String) -> String? {
        if let start = prompt.range(of: "It forks from the page ‘"),
           let end = prompt[start.upperBound...].range(of: "’ (page ID:") {
            return String(prompt[start.upperBound..<end.lowerBound])
        }
        guard let line = prompt.split(separator: "\n").first(where: { $0.hasPrefix("Direction: ") }),
              let open = line.range(of: "‘"),
              let close = line[open.upperBound...].range(of: "’") else { return nil }
        return String(line[open.upperBound..<close.lowerBound])
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    /// Case-insensitive, trimmed, with the trailing question mark optional.
    private static func sameQuestion(_ lhs: String, _ rhs: String) -> Bool {
        func stripped(_ text: String) -> String {
            var text = normalized(text)
            while text.hasSuffix("?") { text.removeLast() }
            return text.trimmingCharacters(in: .whitespaces)
        }
        return stripped(lhs) == stripped(rhs)
    }
}

/// Per-launch pacing for the reading fixture's simulated exploration writer.
///
/// - `LEARNFOLD_READING_TEST_EXPLORATION_DELAY_SECONDS`: one number or a comma
///   list, consumed one value per exploration fork in fork order for this
///   launch (the last value repeats). Absent or unparsable means 1 s, the
///   fixture's original fixed delay.
/// - `LEARNFOLD_READING_TEST_EXPLORATION_GATE_DIR`: when set, a gated fork
///   waits after its delay until `<dir>/release-<trigger>` or
///   `<dir>/release-all` exists (polled every 10 ms, at most 180 s), so a UI
///   test can release the Writing… → New flip at an exact moment.
/// - `LEARNFOLD_READING_TEST_EXPLORATION_GATED`: comma list of triggers to gate
///   (for example `nested_go_deeper`), or `all`. Defaults to `all` when only the
///   gate directory is set.
enum ReadingFixtureExplorationPacing {
    static func delaySeconds(forFork index: Int) -> Double {
        let raw = ProcessInfo.processInfo.environment["LEARNFOLD_READING_TEST_EXPLORATION_DELAY_SECONDS"] ?? ""
        let values = raw.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }.filter { $0.isFinite && $0 >= 0 }
        guard let last = values.last else { return 1 }
        return min(index < values.count ? values[index] : last, 600)
    }

    static func waitForRelease(trigger: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["LEARNFOLD_READING_TEST_EXPLORATION_GATE_DIR"],
              !directory.isEmpty else { return }
        let gated = (environment["LEARNFOLD_READING_TEST_EXPLORATION_GATED"] ?? "all")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard gated.contains("all") || gated.contains(trigger) else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let releases = [
            root.appendingPathComponent("release-\(trigger)").path,
            root.appendingPathComponent("release-all").path,
        ]
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, !releases.contains(where: FileManager.default.fileExists(atPath:)) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
