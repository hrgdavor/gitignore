# Publishing

`@hrg/gitignore` is published under the `hrg` npm scope; `publishConfig` sets `access` to `public`, so a plain
`npm publish` publishes it publicly. This release is **0.3.0** — the same version as `build.zig.zon` and
`pom.xml`. The JavaScript package is plain ESM with no Bun API and no dependencies, so it installs and runs under
Node as well as Bun (`engines.node` is `>=18`).

## Publishing to npm

```text
cd <this checkout>
bun js/conformance.mjs          # 34/34, the vectors are the gate
bun pm pack --dry-run           # 4 files: package.json, README.md, js/gitignore.mjs, js/glob.mjs
npm publish                     # publishConfig supplies --access public
```

**It needs a live token.** Measured on 2026-10-24: `npm whoami` answered `401 Unauthorized` with the token in
`~/.npmrc`, and `npm publish` reported `404 Not Found - @hrg/gitignore@0.3.1`. npm answers 404 rather than 403 when a
token cannot publish to a scope, so the 404 is the *symptom* of an expired/revoked token, not of a missing package
(`npm owner ls @hrg/gitignore` works and names `hrgdavor`, and 0.3.0 is on the registry). Fix with `npm login`, then
publish; no change to this repository is needed.

`fs-meta` pins `"@hrg/gitignore": "0.3.0"` exactly, which is the published version. Bump that one line to `"0.3.1"` when
npm has it.

After it is on the registry, [`fs-meta`](https://github.com/hrgdavor/fs-meta)'s `package.json` should switch its
`@hrg/gitignore` dependency from the local `file:` link to the published version range (`^0.3.0`), exactly as the
Java port moves from a local `mvn install` to the released `hr.hrg:gitignore:0.3.0`.

## Publishing the Maven artifact

The release is **0.3.0**, the same version as `build.zig.zon` and `package.json`. Publishing is deliberate now:
the Central publisher lives only in [`pom-release.xml`](pom-release.xml), and `pom.xml` has no publisher at all.

### Why the publisher is not in `pom.xml`, and never in a profile

Maven reads `<extensions>true</extensions>` only from a POM's **top-level `<build>`**, never from a profile. The
publisher was once declared in the `publish` profile; it silently never loaded, so `deploy` staged a bundle and
stopped — no upload, and not a word about "central" in the log. That is the failure this layout prevents.

Declaring it in `pom.xml`'s top-level `<build>` does load it, but then *every* build loads it and a bare
`mvn deploy` publishes to Central whether or not `-Ppublish` was passed. So the publisher is kept out of `pom.xml`
entirely and exists only in `pom-release.xml`, in that POM's top-level `<build>`.

The guard has two halves:

- `pom.xml` sets `maven.deploy.skip=true`. `mvn deploy` on it reaches `maven-deploy-plugin` and logs
  `Skipping artifact deployment`; it uploads nothing, and the publisher is not on the build's classpath at all.
- `pom-release.xml` is a copy of `pom.xml` plus the publisher. It keeps `maven.deploy.skip=true` too: that property
  disables `maven-deploy-plugin`, **not** the Central publisher, which is a separate goal at the same phase. If the
  extension ever failed to load, the release would do nothing rather than fall back to a direct deploy. Verified with
  the plugin: with `maven.deploy.skip=true`, `central-publishing:0.6.0:publish` still runs and logs
  `Skipping Central Publishing at user's request.` when `-DskipPublishing=true` is passed.

`pom-release.xml` is a **copy**, not a child: Maven 3.9.9 rejects a jar-packaged POM as a parent
(`Invalid packaging for parent POM ... must be "pom" but is "jar"`), and Maven has no POM include. Everything is
duplicated; only the comment block and the publisher plugin are meant to differ. [`scripts/check-poms.mjs`](scripts/check-poms.mjs)
strips comments, removes the publisher, and fails if anything else differs; it also asserts that both POMs declare the
same version. Run `bun scripts/check-poms.mjs` after editing either POM, and copy `pom.xml` again in the same commit.

### The release command

**On this machine `mvn` is `mvnd` (native mode), not the real Maven, and it refuses `-Dmvnd.noDaemon`.** Releasing uses
the unpacked real Maven in `.tmp/maven/` (Maven 3.9.9), with JDK 25:

```text
$env:JAVA_HOME = 'C:\Program Files\Java\jdk-25'
$env:MAVEN_GPG_PASSPHRASE = '<your passphrase>'
.tmp\maven\apache-maven-3.9.9\bin\mvn.cmd -f pom-release.xml -Ppublish -DskipTests package
.tmp\maven\apache-maven-3.9.9\bin\mvn.cmd -f pom-release.xml -Ppublish -Dgpg.skip=false -DskipTests deploy
```

The first command checks that the binary, sources and javadoc jars all appear in `target/`; the second is the release.
`-Ppublish` adds `maven-source-plugin`, `maven-javadoc-plugin` and `maven-gpg-plugin` (the profile is in both POMs).
`gpg.skip` defaults to `true`, so nothing signs unless `-Dgpg.skip=false` is passed.

To exercise the release path **without uploading**, pass the publisher's own switch:

```text
.tmp\maven\apache-maven-3.9.9\bin\mvn.cmd -f pom-release.xml -DskipTests -DskipPublishing=true deploy
```

That runs `central-publishing:0.6.0:publish`, stages and bundles locally, logs
`Skipping Central Publishing at user's request.`, and stops before the upload. **Do not** prove the release path with a
bare `deploy`.

Requirements, learned from a project of this author's that publishes this way (`dia-log`):

- `~/.m2/settings.xml` has a server with id **`central`** carrying the Sonatype token.
- **The signing passphrase comes from `MAVEN_GPG_PASSPHRASE`**, not from `settings.xml`: the plugin deprecates
  `passphraseServerId` (it warns that a passphrase in a file can leak), and the profile passes
  `--pinentry-mode loopback` so gpg reads the environment instead of trying to open a prompt that a batch build cannot
  answer. Measured on this machine: with the variable set, a wrong value produces `gpg: signing failed: Bad passphrase`
  (proving the passphrase reaches the key); with it unset the agent answers `Operation cancelled`, which is what a GUI-less
  run looks like. A passphrase stored in `settings.xml` under the old id is ignored now.
- `gpg.skip` defaults to `true`, so a local build never signs; the release passes `-Dgpg.skip=false`.
- The Central publisher takes over the `deploy` phase and suppresses `maven-deploy-plugin`, so the
  `distributionManagement` in both POMs (Sonatype's `maven-releases` endpoint) is not a second upload path. The
  publisher uses `skipPublishing` to stop before the upload and the `central` server for credentials; it does **not**
  use `altDeploymentRepository`.
- The version comes from the POM (`0.3.0`), and `build.zig.zon`/`package.json` must agree — they do.

Afterwards, `fs-meta` resolves `hr.hrg:gitignore` from the repository like any other artifact; it no longer needs the local
`mvn install`.
