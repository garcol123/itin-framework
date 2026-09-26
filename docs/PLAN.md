# Migration plan

1. **Baseline and inventory** — record source Git identity/status, run its
   validator and tests, inventory assumptions, and preserve committed HTML,
   normalized visible content, journey payload, and screenshots.
2. **Mechanical extraction** — move the working engine into shared directories
   and the unchanged Japan instance into `examples/japan`.
3. **Configuration and generic model** — add validated `site.yaml`, generic
   currencies and rail classifications, trip-root-aware renderers, and safe map
   fallback handling.
4. **Public commands and starter** — implement every required CLI, a blank starter,
   Make targets, privacy behavior, route refresh, and Sites-compatible output.
5. **Contracts and compatibility** — add a complete non-Japan fixture, framework
   and CLI tests, ported Japan tests, semantic/DOM/payload comparisons, and
   deterministic/security scans.
6. **Documentation and visual QA** — document architecture and trip creation,
   inspect all Japan pages at desktop/mobile sizes, record intentional differences,
   and verify the source repository remains unchanged.

Each milestone must pass its affected tests before a coherent local commit.
