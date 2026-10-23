// The Java port against the conformance vectors.
//
// Plain Java, no JUnit and no Maven: the vectors are JSON and a runner that needs a build system to say "34/34" would be
// a second project inside this one. Exit code 1 on any disagreement, so it is a gate.
//
// Usage: java -cp <classes> hr.hrg.gitignore.Runner <conformance/gitignore-vectors.json>
package hr.hrg.gitignore;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Optional;

public final class Runner {
    private Runner() {
    }

    public static void main(String[] args) throws IOException {
        if (args.length != 1) {
            System.err.println("usage: Runner <conformance/gitignore-vectors.json>");
            System.exit(2);
        }
        String text = Files.readString(Path.of(args[0]), StandardCharsets.UTF_8);
        Map<?, ?> document = (Map<?, ?>) Json.parse(text);
        List<?> cases = (List<?>) document.get("cases");

        List<String> failures = new ArrayList<>();
        System.out.println();
        System.out.println("| case | expected | observed | |");
        System.out.println("| ---- | -------- | -------- |-|");
        for (Object entry : cases) {
            Map<?, ?> testCase = (Map<?, ?>) entry;
            String name = (String) testCase.get("name");
            String path = (String) testCase.get("path");
            boolean isDirectory = Boolean.TRUE.equals(testCase.get("isDir"));
            String expect = (String) testCase.get("expect");

            String observed;
            Path root = Files.createTempDirectory("gitignore-java-");
            try {
                observed = decideIn(root, testCase, path, isDirectory);
            } finally {
                deleteTree(root);
            }
            boolean pass = expect.equals(observed);
            if (!pass) {
                failures.add(name);
            }
            System.out.printf("| %s | %s | %s | %s |%n", name, expect, observed, pass ? "pass" : "**fail**");
        }

        int passed = cases.size() - failures.size();
        System.out.println();
        System.out.printf("%d/%d cases agree%n", passed, cases.size());
        if (!failures.isEmpty()) {
            System.err.println("disagreed: " + String.join("; ", failures));
            System.exit(1);
        }
    }

    /** Materialises the case's rule files under {@code root} and asks the port. */
    private static String decideIn(Path root, Map<?, ?> testCase, String path, boolean isDirectory) throws IOException {
        List<?> ruleFiles = (List<?>) testCase.get("ruleFiles");
        List<Map<?, ?>> ordered = new ArrayList<>();
        for (Object entry : ruleFiles) {
            ordered.add((Map<?, ?>) entry);
        }
        // Shallowest first: GitIgnoreRules consults its stack from the top, so the deepest file answers first.
        ordered.sort(Comparator.comparingInt(file -> ((String) file.get("dir")).split("/").length));

        GitIgnoreRules stack = new GitIgnoreRules();
        for (Map<?, ?> file : ordered) {
            String directory = (String) file.get("dir");
            String rules = (String) file.get("rules");
            Path target = directory.isEmpty() ? root : root.resolve(directory);
            Files.createDirectories(target);
            Files.writeString(target.resolve(GitIgnoreFile.FILE_NAME), rules, StandardCharsets.UTF_8);
            stack.push(GitIgnoreFile.parse(directory, rules));
        }

        Optional<Boolean> decision = stack.decide(path, isDirectory);
        if (decision.isEmpty()) {
            return "no-opinion";
        }
        return decision.get() ? "exclude" : "include";
    }

    private static void deleteTree(Path root) throws IOException {
        if (!Files.exists(root)) {
            return;
        }
        try (var walk = Files.walk(root)) {
            for (Path entry : walk.sorted(Comparator.reverseOrder()).toList()) {
                Files.deleteIfExists(entry);
            }
        }
    }
}
