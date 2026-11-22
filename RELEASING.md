# Making a release

The package holds the SHA-256 of each released daemon
(`lisp/tandem-daemon-sums.el`), and `M-x tandem-install-daemon` refuses
a download that does not match. The release workflow rebuilds the
daemons and publishes them only if they are byte for byte those. That
works because the build is reproducible with the same Go (`make dist`
uses `-trimpath`, `-buildvcs=false` and an empty build ID, and refuses any
Go but `GO_RELEASE` in the `Makefile`).

1. Set the version, the same in three places: `;; Version:` in
   `lisp/tandem.el`, `tandem-version` in `lisp/tandem-rpc.el` and
   `Version` in `daemon/internal/version/version.go`.
2. With exactly the Go of `make print-go-release`:

   ```sh
   make check
   make dist sums        # dist/ and lisp/tandem-daemon-sums.el
   make check-sums       # dist/ matches what the package will hold
   ```

3. Commit, including `lisp/tandem-daemon-sums.el`; tag `vX.Y.Z`; push the
   commit and the tag.
4. The `release` workflow checks that the tag matches the versions,
   builds with the same Go, runs `make check-sums`, and only then
   publishes `dist/*` as the GitHub release.

To try a package install end to end before releasing:

```sh
make test-package PACKAGE_BUILD=/path/to/melpa/package-build [COMPAT=/path/to/compat]
```

It builds tandem from the checkout as MELPA does (`recipes/tandem`),
installs it in a fresh Emacs, installs the daemon from a local release
with the SHA-256 check, and chats with the fake claude.
