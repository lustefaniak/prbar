## TypeScript / React-specific watchpoints

- **`any` and type assertions** — `as Foo` and `any` defeat the type system. Each one needs a justification (or a TODO with a ticket).
- **Floating promises** — `someAsync()` without `await` or `.catch()` silently swallows errors. Look for promises in event handlers and `useEffect` bodies.
- **`useEffect` without dependencies declared correctly** — missing deps lead to stale closures; including non-stable refs (objects, arrays, functions defined inline) lead to render loops.
- **State updates in render** — `setState(...)` inside a render body without a guard infinite-loops.
- **Conditional hooks** — Rules of Hooks: hooks must run unconditionally, in the same order every render. `if (x) useState(...)` is a bug.
- **Direct DOM access** — `document.querySelector` etc. inside React components usually means the team hasn't reached for a ref or a portal.
- **Server-only code in client bundles** — `process.env.SOME_SECRET` referenced in a file that ships to the browser. With Next.js, `NEXT_PUBLIC_*` names are public; anything else is server-only.
- **Untyped errors in catch** — `catch (err)` infers `unknown` (TS 4.4+). Calling `err.message` without narrowing is a runtime error.
- **List rendering without stable keys** — `key={index}` for reorderable lists causes wrong state attribution.
- **Hardcoded URLs / IDs** — usually means a config value or env var got lost.

For Tailwind / CSS-in-JS: ignore class-name ordering and minor whitespace.
