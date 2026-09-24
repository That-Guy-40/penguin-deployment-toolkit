# Tutorials

Deep-dive tutorials on That-Guy-40 projects. Each one reads the real source
line by line and comes with labs you can run on one Linux box. Technical
terms are introduced one at a time, in plain language, before they're used.

> **Staging note:** this folder is laid out as the root of a standalone
> `tutorials` repository. It lives here for now because the session that
> wrote it could not create a new GitHub repository. To move it:
>
> ```bash
> # after creating an empty That-Guy-40/tutorials repo on GitHub
> cp -r tutorials/. /path/to/new/tutorials-checkout/ && cd /path/to/new/tutorials-checkout
> git add . && git commit -m "Import tutorials" && git push
> ```

## Index

| Tutorial | Project | What it covers |
|----------|---------|----------------|
| [socwrap, phases 1 and 2](socwrap/README.md) | [`socwrap`](https://github.com/That-Guy-40/socwrap) | Starts from zero: a building-blocks primer (processes, pipes, signals, sockets) and a glossary, then Phase 1 line by line, then Phase 2's network modes, and six real bugs with tested fixes. Assumes no prior jargon. |
