# Tickets: Enmetry

Build the Enmetry addon end to end - a passive Ashita v4 enmity tracker for
HorizonXI that reconstructs the server's enmity container from observed packets
and renders per-player CE/VE with an honest uncertainty band. Design decisions
are settled in `DESIGN.md`.

Work the **frontier**: any ticket whose blockers are all done. Tickets 1 and 2
are both frontier immediately and can run in parallel. After the deterministic
sim lands, mob tracking and action coverage both open at once.
After the particle filter lands, nearly everything else does.

Clear context between tickets.

## Addon skeleton with live action feed

**What to build:** The addon loads in game, responds to its command, and draws a
chromeless canvas on screen. It ingests action and message packets, resolves the
entities involved, and shows a live list of what it observed. No enmity yet -
this proves the packet path and the render path in one pass.

**Blocked by:** None - can start immediately.

- [x] Loads and unloads cleanly with no errors in the console
- [x] The addon command responds with a status line
- [x] A chromeless canvas renders, is draggable, and its position persists globally
- [x] Action and message packets parse into structured events carrying actor, target, category and parameters
- [x] Entity indices resolve to names; alliance membership and main/sub job are readable for all 18 slots
- [x] A debug view lists recent observed actions live and can be toggled off

## Enmity data table generator

**What to build:** A regeneratable source of truth for every number the sim
needs. One command produces the vendored tables; each entry says where it came
from and how much it should be trusted.

**Blocked by:** None - can start immediately.

- [x] A single command regenerates all vendored tables from source
- [x] Action table carries base CE/VE per ability and spell, each tagged era-verified, LSB-default or unknown
- [x] Horizon-specific deltas are applied, each individually commented with its source
- [x] Mobskill table maps skill identity to its enmity effect - full reset, partial reduction, or none
- [x] Mob level ranges are available per zone
- [x] Every entry carries a provenance header so regeneration is reproducible rather than archaeological
- [x] Tests assert known entries survive regeneration unchanged

## Deterministic enmity sim - damage, cure, decay, bars

**What to build:** The tracer bullet. Melee a mob and watch enmity accrue and
decay on screen in real time, with CE and VE shown as distinct parts of the
total. Hidden bonuses are pinned at neutral and no uncertainty is displayed yet -
this ticket is about the replay engine being *correct*.

**Blocked by:** Addon skeleton with live action feed; Enmity data table generator.

- [ ] Enmity accrues from damage dealt, using the mob-level divisor
- [ ] CE is reduced when a tracked actor takes damage, derived from observed HP percentage delta
- [ ] Cure enmity accrues using the cure target's level, not the mob's
- [ ] VE decays at 60 per second and floors at zero; CE never decays
- [ ] CE and VE are each capped independently
- [ ] The first actor onto an empty hate list receives the first-engage bonus
- [ ] Actions from beyond enmity range contribute nothing
- [ ] Bars render CE and VE as distinct segments on the absolute-to-cap scale, with a marker at the leader's total
- [ ] Hidden bonuses are fixed at neutral; no uncertainty is drawn

## Mob tracking, focus selection and integrity tiers

**What to build:** The panel stops being about one mob and starts behaving like
a real tool - it follows what you're fighting, keeps state for everything else,
appears and disappears on its own, and is honest about when it doesn't know
enough to show absolute numbers.

**Blocked by:** Deterministic enmity sim - damage, cure, decay, bars.

- [ ] Every engaged mob has its own simulated hate list, maintained simultaneously
- [ ] Display focus follows the player's current target
- [ ] With no engaged target, focus falls back to the mob the most alliance members are acting on
- [ ] A pin command locks focus until released
- [ ] The panel appears when something is engaged and hides itself when nothing is
- [ ] Mobs whose engage was witnessed from empty show absolute values; others show ordering and deltas only, and are visually distinguished
- [ ] When an unmodelled entity holds hate it appears as a top row without a bar, and the leader marker is hidden
- [ ] The configurable top-N limit on displayed bars is respected

## Full action coverage and Horizon buff overlays

**What to build:** Everything a real fight actually contains - abilities, spells,
cures that hit multiple mobs, and the Horizon-specific rules that change enmity
depending on what buffs are up and whether a job is main or sub.

**Blocked by:** Deterministic enmity sim - damage, cure, decay, bars.

- [ ] Abilities and spells contribute their table CE/VE, with only positive values scaled by the bonus
- [ ] Cure enmity applies to every tracked mob whose hate list contains the healed player, and to no others
- [ ] In-range enmity applies to every tracked mob already hating the actor
- [ ] Sentinel, Yonin and Defender are read from party buffs and applied as known overlays with correct durations
- [ ] Provoke receives the Horizon Defender bonus at the correct value for main versus sub job
- [ ] Subjob-conditional gear effects are applied
- [ ] The trust tier of every action used is tracked, ready to widen uncertainty later

## Edge mechanics

**What to build:** The mechanics that move enmity in ways the main formulas
don't describe. Each is small on its own; together they're the difference between
a sim that tracks a real fight and one that quietly drifts.

**Blocked by:** Full action coverage and Horizon buff overlays.

- [ ] Cover grants the coverer CE and reduces the covered target, and the coverer takes no normal CE loss on that hit
- [ ] Issekigan grants CE per parry
- [ ] Shadow absorb applies its CE loss according to the configured behaviour flag
- [ ] Killing the current highest-enmity holder clears their entry entirely; killing anyone else only deactivates them
- [ ] Inactive entries are excluded from target selection and reactivate when hit while alive
- [ ] Trick Attack redirects the full damage enmity to a geometrically inferred partner, scaled by that partner's bonus

## Particle filter core

**What to build:** The addon stops assuming everyone is neutral and starts
inferring what their hidden enmity gear must be, from whether the mob's choice of
target matches what the sim predicted.

**Blocked by:** Mob tracking, focus selection and integrity tiers; Full action coverage and Horizon buff overlays.

- [ ] Particles carry both a candidate bonus vector and a full per-actor enmity state
- [ ] Latent structure is per player per action class, sharing a per-player prior
- [ ] An observed action updates every particle with no per-frame allocation
- [ ] Target observations reweight particles via a soft likelihood on the enmity margin, so one surprise cannot collapse the filter
- [ ] Observations where the target is not a modelled actor are discarded rather than used
- [ ] Switch instants are weighted more heavily than steady-state observations
- [ ] Resampling occurs only when effective sample size drops below threshold
- [ ] Particle count scales automatically to hold the frame budget in an 18-member fight
- [ ] Bars display the posterior median

## Priors and per-character memory

**What to build:** The filter stops starting from ignorance every night. It
begins from what the player's job implies, and from whatever it concluded about
that specific character last time.

**Blocked by:** Particle filter core.

- [ ] Initial belief is shaped by main job
- [ ] Posteriors persist per server and character between sessions
- [ ] A stored posterior decays back toward the job prior with time since last seen
- [ ] Stored data is plaintext and inspectable by hand
- [ ] Forget-by-name and blanket purge commands both work
- [ ] Nothing is transmitted anywhere

## Surprise detector and mobskill reset table

**What to build:** The addon learns to say "something happened I can't explain"
instead of blaming a player's gear for it - and stops being surprised by the most
common cause, mob abilities that wipe hate.

**Blocked by:** Edge mechanics; Particle filter core.

- [ ] Mobskill hate resets and partial reductions are applied from the table
- [ ] Observations inconsistent with essentially all particles trigger a discontinuity instead of a resample
- [ ] A surprise refits: the two involved are redrawn across the Enmity clamp and the fight replays through them; only one even that cannot explain re-anchors the member above the leader, keeping the list absolute, and the panel says so (changed from dropping to ordering-only after the 2026-09-13 Jailer of Love logs: a terminal drop left the filter blind for the rest of the fight)
- [ ] An unexplained switch following a mobskill absent from the table is logged as a table gap

## Uncertainty rendering - the alpha ramp

**What to build:** The bar starts telling the truth about what it doesn't know.
Solid where the value is certain, fading outward through everything it might be,
narrowing visibly as the addon learns.

**Blocked by:** Particle filter core.

- [ ] Credible bounds are derived from the posterior
- [ ] The bar is fully opaque out to the lower bound
- [ ] Alpha beyond the lower bound falls in proportion to posterior density, reaching zero at the upper bound
- [ ] A median tick is drawn
- [ ] The translucent region visibly narrows as belief converges
- [ ] Rendering uses vertex gradients rather than baked textures

## Live calibration readout

**What to build:** A number that says whether to believe the addon. It records
what it predicted before each target switch, scores itself afterwards, and shows
whether its confidence bands are honest.

**Blocked by:** Particle filter core.

- [ ] A prediction is recorded before each observed target switch and scored after
- [ ] The readout shows observed coverage of the credible interval against its nominal level
- [ ] It resets per session and can be shown on demand

## Research registry and offline analysis tool

**What to build:** Turn the addon into an instrument. Open questions about
Horizon's behaviour get logged as they occur in play, and a separate tool scores
competing explanations against the accumulated evidence.

**Blocked by:** Edge mechanics; Particle filter core.

- [x] Registry entries declare a prior, a hypothesis set, qualifying-observation criteria, and a persisted posterior
- [x] Qualifying events are written to a structured local log
- [x] Live display runs only the simplest hypothesis so bars stay sensible
- [x] The summoner avatar enmity share and the shadow-absorb rule are both registered
- [x] The offline tool scores competing hypotheses against the log and reports relative fit
- [x] Nothing is transmitted and there is no export path

## Settings panel and configuration

**What to build:** Everything that was a constant becomes a choice - how many
bars, what colours, which behaviour flags - adjustable in game and
remembered.

**Blocked by:** Mob tracking, focus selection and integrity tiers; Uncertainty rendering - the alpha ramp.

- [x] The panel opens via command and uses real widgets
- [x] Top-N, colours, fonts and behaviour flags are all configurable
- [x] Changes apply immediately without a reload
- [x] Settings and panel position persist globally, not per character
- [x] The panel respects the game's UI hide state

## Per-entry era-vs-LSB value inference

**What to build:** The generated table carries two values for the 171 abilities
and spells where the era enmity table and LandSandBoat disagree (Rampart 1/300
vs 320/320, bard songs and most enfeebles at roughly half), and the `values`
setting picks one set for the whole sim. Nobody knows which Horizon runs, entry
by entry. Turn that into a registry question: each disagreeing entry, or each
family of them (songs, bar-spells, -na spells, Rampart), is a two-hypothesis
research entry scored from the fights where it was used, and the live sim keeps
applying whichever the setting says until the posterior is decisive.

**Blocked by:** Research registry and offline analysis tool; Settings panel
and configuration.

**Why it can wait:** Against the local LandSandBoat server the `values = lsb`
setting already makes the replay exact, and on Horizon the disagreements are
small beside gear and the cap for everything except Rampart. Against a
LandSandBoat server, Rampart under Sentinel was the whole of the remaining
error on 2026-09-13 (640 CE a cast).

- [ ] Each disagreeing entry, or a named family of them, is a registry entry with prior, hypotheses era and lsb, and a persisted posterior
- [ ] An application qualifies as evidence only on a clean list where the two hypotheses predict different targets, or differ by more than the filter's band
- [ ] The offline tool reports per-family relative fit from the session logs
- [ ] The live sim follows the `values` setting until a family's posterior passes a threshold, then applies the winner and says so in the log
