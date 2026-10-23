// The Java port's bench CLI: the same contract as the Zig and JS ones, so the runner times all three on identical bytes.
//
//   java -cp <classes> hr.hrg.gitignore.Decide --rules <file.gitignore> --paths <file.paths> [--dirs <file>]
//
// One verdict per line on stdout, in input order: include | exclude | no-opinion. The stack is built once and the output
// is collected before it is written, because the runner times a process and a syscall per line would be the thing it
// measured.
package hr.hrg.gitignore;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

public final class Decide {
    private Decide() {
    }

    public static void main(String[] args) throws IOException {
        String rules = null;
        String paths = null;
        String dirs = null;
        for (int index = 0; index < args.length; index++) {
            switch (args[index]) {
                case "--rules" -> rules = args[++index];
                case "--paths" -> paths = args[++index];
                case "--dirs" -> dirs = args[++index];
                default -> usage("unexpected argument: " + args[index]);
            }
        }
        if (rules == null || paths == null) {
            usage("--rules and --paths are both required");
        }

        String ruleText = Files.readString(Path.of(rules), StandardCharsets.UTF_8);
        String flags = dirs == null ? null : Files.readString(Path.of(dirs), StandardCharsets.UTF_8).replaceAll("\\s+", "");
        List<String> names = new ArrayList<>();
        for (String line : Files.readAllLines(Path.of(paths), StandardCharsets.UTF_8)) {
            if (!line.isEmpty()) {
                names.add(line);
            }
        }

        GitIgnoreRules stack = new GitIgnoreRules();
        stack.push(GitIgnoreFile.parse("", ruleText));

        StringBuilder out = new StringBuilder(names.size() * 8);
        for (int index = 0; index < names.size(); index++) {
            boolean isDirectory = flags != null && (flags.length() == 1 ? flags.equals("1") : flags.charAt(index) == '1');
            var decision = stack.decide(names.get(index), isDirectory);
            if (decision.isEmpty()) {
                out.append("no-opinion");
            } else {
                out.append(decision.get() ? "exclude" : "include");
            }
            out.append('\n');
        }
        System.out.print(out);
    }

    private static void usage(String message) {
        System.err.println(message);
        System.err.println("usage: Decide --rules <file.gitignore> --paths <file.paths> [--dirs <file>]");
        System.exit(1);
    }
}
