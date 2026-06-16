# Cloud Foundry Documentation Reference

Conventions and patterns for writing user-facing documentation in the Cloud Foundry ecosystem.

**When using this reference, state:** "I'm applying Cloud Foundry documentation conventions: ERB templating, CF-specific formatting, and CF workflow patterns."

---

## File formats and templating

CF docs use ERB templating (`.html.md.erb`). Variables are referenced as `<%= vars.foo %>`.

Common variables:
- `<%= vars.app_runtime_abbr %>` — abbreviated platform name (e.g., "CF")
- `<%= vars.app_runtime_first %>` — full platform name on first use
- `<%= vars.platform_code %>` — used in conditionals: `<% if vars.platform_code == 'CF' %>`

"Cloud Foundry" as a proper noun (API name, spec name, CLI name) is not parameterized.

---

## Document structure

### Anchors
Every heading gets an anchor for deep linking:
```markdown
## <a id='section-name'></a> Section Title
```

Use lowercase, hyphenated anchor IDs matching the heading text.

### Terminal output
Use `<pre class="terminal">` blocks for command output, not fenced code blocks:
```html
<pre class="terminal">
$ cf set-org-role huey<span>@</span>example.com example-org OrgManager
Assigning role OrgManager to user huey<span>@</span>example.com in org example-org as admin...
OK
</pre>
```

Use plain fenced code blocks for command syntax (without output):
````markdown
```
cf set-org-role USERNAME ORG ROLE
```
````

### Parameter lists
Use `<ul>` / `<li>` HTML lists (not Markdown) for parameter descriptions inside numbered procedures, to avoid breaking the numbered list:
```html
Where:
<ul>
  <li>`USERNAME` is the username of the user.</li>
  <li>`ORG` is the name of the org.</li>
</ul>
```

### Notes and warnings
```markdown
> **Note:** Text here.
> **Important:** Text here.
```

---

## Cross-linking

Use relative paths from the current file:
```markdown
[Roles](../../concepts/roles.html)
[Managing roles](./managing-roles.html)
```

Verify anchors exist in the target file before linking to them (e.g., `roles.html#clients`).

---

## Researching a CF feature

### Finding implementation commits
```bash
git log --oneline --all | grep -i "ISSUE-ID\|feature-keyword"
git show COMMIT_HASH
```

### Verifying CLI flag behavior
Read the command's `validateFlags()` or equivalent method — proposal documents and design docs often describe intended behavior that differs from what was actually shipped.

### Identifying unimplemented scope
Compare the proposal or design doc against the git history. Features described in the design but absent from commits are unimplemented. These either become "known limitations" or are omitted entirely — do not document behavior that doesn't exist yet.

---

## Example formatting

Use `<span>@</span>` to escape `@` in email addresses in terminal output blocks (prevents email harvesting).

For LDAP distinguished names, use the full DN format: `cn=app-developers,ou=groups,dc=mycompany,dc=org`

---

## Common mistakes

- **Relative links to non-existent anchors** — verify anchors exist in the target file before linking (e.g., `roles.html#clients`).
