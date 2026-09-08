# Rose Claude Guidelines

Read `AGENTS.md` completely before editing and the relevant `SKILLS.md` section before
running checks. Do not assume these files were automatically loaded. Surface conflicts
instead of silently weakening strict Lua checks or changing repository formatting.

## Working habits

- **Think first:** inspect relevant code; state assumptions and ask about material ambiguity.
  Suggest simpler alternatives where appropriate.
- **Keep it simple:** minimum requested code, no speculative features or frameworks.
- **Edit surgically:** preserve APIs, commands, configuration and unrelated work.
  Remove only dead code created by your changes.
- **Verify goals:** define checks, reproduce the bug, implement and review the tested final
  diff. Missing tools, skipped files and empty cached diagnostics are not passes.

Preserve native-mode independence and Rose's two-space/double-quote/100-column formatting.
Fix actual optional I/O/module/uv boundaries with precise types and guards, not blanket casts
or suppressed nil diagnostics. Follow the Astra6/Fable5.1 handoff requirement in `AGENTS.md`
for substantive work without claiming that instructions make models equally capable.
