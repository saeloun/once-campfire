# Deccan Queen theme

The standalone Campfire theme uses original artwork already committed to
[saeloun/dqor-tickets](https://github.com/saeloun/dqor-tickets/tree/de21ebff3a9f0f80aa9182603e1f216fcd1ffc41),
at source revision `de21ebff3a9f0f80aa9182603e1f216fcd1ffc41`. The logo is copied byte for byte. The original hero artwork is encoded as
WebP at its unchanged 1536 × 1024 dimensions; no third-party visual assets
or fonts are downloaded. The source repository's
MIT license, copyright 2026 Saeloun, is retained verbatim in
`docs/deccan-queen-assets-LICENSE`. Campfire's existing 37signals MIT license
remains in `MIT-LICENSE`.

## Asset mapping

| Embedded destination | Source at the pinned revision | SHA-256 |
| --- | --- | --- |
| `app/assets/images/deccan-queen/deccan-logo.png` | `public/dqor/deccan-logo.png` | `0a413deb3c1658eaab426d4e9140737a2d8188964d0846c3f506721c0f10e7f3` |
| `app/assets/images/deccan-queen/hero-bg.webp` | WebP derivative of `public/dqor/hero-bg.jpg` | `f25a73ed54d0dfc3735355c37be529ec2a0ddfba02eecf4ab10573943bdaf00d` |

The source `public/dqor/hero-bg.jpg` is PNG-encoded despite its filename.
Its original SHA-256 is `d1b3da52438ff663afdb22cb1da4b743146a716e0a6bdbffb218dc7d675a3e46`
and size is 4,767,292 bytes. The release derivative is 619,522
bytes, retaining the original dimensions and artwork. Reproduce it from the
pinned source with the existing `cwebp` tool:

```sh
git -C /path/to/dqor-tickets show de21ebff3a9f0f80aa9182603e1f216fcd1ffc41:public/dqor/hero-bg.jpg > /tmp/dq-hero-source.png
cwebp -q 82 -m 6 /tmp/dq-hero-source.png -o app/assets/images/deccan-queen/hero-bg.webp
```

The artwork appears behind opaque entry panels; the logo appears in entry,
sidebar and empty states. Message backgrounds remain plain and opaque.
CSS assets use the native `make assets` workflow's existing relative asset
references. The compiled service serves the embedded stylesheet and image
under `/assets`; no Rails/Propshaft rewrite is assumed.

## Palette and typography

Warm ivory `hsl(40 30% 96%)`, ruby/plum `hsl(348 70% 35%)`, rose
`hsl(20 45% 92%)`, and their dark equivalents derive from the pinned
`app/assets/stylesheets/global.css`. The adaptation uses dark gray body text,
16px chat text, 1.4 line height, and the existing message width capped at 80ch.
Dark small links and primary buttons use `hsl(348 68% 64%)` for contrast;
unread room labels use the body text color. Inter is preferred when installed, with local sans-serif fallbacks; no font
service or network dependency is introduced. Typography follows
[Practical Typography](https://practicaltypography.com/typography-in-ten-minutes.html).

## Integration

`deccan_queen.css` is explicitly linked after the existing asset stylesheets
and before account custom styles. The explicit link gives deterministic theme
precedence even when the existing `:all` helper also includes it.
Light and dark colors follow the existing operating-system preference.
Reduced motion suppresses decorative entry/loading movement and minimizes
existing transitions. Flash messages show readable notice text. Reduced motion keeps each notice
visible for three seconds without movement; animation completion still fires
to preserve its existing removal behavior.

The theme changes styles, presentation templates and static error pages. The
startup page retains its original ten-second retry. Authentication, Google
SSO, invitations, role checks, membership, revocation, message rendering and
delivery logic are unchanged. Room controls retain their existing links,
form actions, IDs, Turbo frames and Stimulus actions.

The deployment binary must be compiled through the existing Campfire/Spinel
asset and build workflow, then exercised with synthetic local data. Source
changes alone are not evidence that the binary includes or serves the theme.

## Native compatibility

The password sign-in form uses ordinary full-page submission, matching the
existing Google sign-in form. This preserves the unauthorized response's
visible flash notice instead of losing it when Turbo reloads the sign-in page.
Authentication, credential checks, status codes and session handling are unchanged.

The no-room welcome controller explicitly renders `:show`. Rails accepts its
previous argument-free `render`, but the compiled runtime requires the template
argument. This fixes the native empty-state response without changing room
visibility, membership or roles.

The message edit form explicitly uses `method: :patch`. Rails infers PATCH
from the saved message, while the compiled explicit-URL form defaults to POST
without this option. The explicit method sends Save to the existing update
route and preserves its ownership and administrator checks.

## Runtime dashboard

The dashboard keeps the DQOR palette and shows performance metrics before
build hashes. Native build evidence uses a keyboard-accessible disclosure.
CPU, memory, throughput and latency use distinct colors and labelled peak
values with units; missing samples remain visible as gaps. Fresh, stale and
unavailable telemetry have explicit labels.

The dashboard release is `dqor-campfire:be39e42-cd46362`, compiled from
Campfire `cd463624bf1d720d76dd578836c8b6e9fed8919a` and the already-deployed
Roundhouse `be39e428ef6f3a47719d3ab9a46041133146178a`. The focused check is
`node test/javascript/runtime_stats_controller_test.mjs`. The importmap versions the
dashboard controller URL with `?v=dqor-dashboard-20261003`, so existing browser
sessions fetch the updated controller on their next dashboard navigation.
The native compiler adds `/assets/` to relative importmap targets; keep this
pin relative to avoid generating a duplicated asset path. Native and Rails
sign-in checks passed (33 runs, 134 assertions for the Rails controller checks).
