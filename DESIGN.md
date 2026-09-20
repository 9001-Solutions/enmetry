# Enmetry - Design Specification

An Ashita v4 addon for HorizonXI that reconstructs the server's enmity container
from passively observed packets, and renders per-player CE/VE with an honest
uncertainty band over each player's invisible Enmity+/- gear and merits.

It reads. It sends no packets, acts for no one, and automates nothing.

---

## 1. Target

- **Server:** HorizonXI (75-era, era+), no server-side cooperation.
- **Posture:** strictly passive observer.
- **Enmity cap:** hardcoded **10000** for CE and **10000** for VE, independently.
  LSB treats this as a config value (`settings/default/map.lua:66` = 30000);
  AirSkyBoat hardcodes the era value (`src/map/enmity_container.h:42`). Horizon
  rebased onto LSB in Jan 2026, so this is an assumption, not a verified fact -
  see section 13.

---

## 2. Server model

All formulas verified against LandSandBoat at the pinned checkout. AirSkyBoat is
byte-identical except for the cap.

| Quantity | Formula | Source |
|---|---|---|
| Enmity multiplier | `(100 + clamp(ENMITY + meritInc - meritDec, -50, +100)) / 100` -> 0.50x-2.00x. **Positive CE/VE only**; losses are never scaled. | `enmity_container.cpp:141` |
| Damage dealt | `CE = 80/M * dmg`, `VE = 240/M * dmg`, `M = mobLevel * 31/50 + 6` | `battleutils.cpp:408` |
| Cure | `CE = 40/C * amt`, `VE = 240/C * amt`, `C` from the **cure target's** level | `battleutils.cpp:413` |
| Damage taken | `CE -= 1800 * dmg/maxHP * (100 - min(ENMITY_LOSS_REDUCTION,100))/100`. VE untouched. | `enmity_container.cpp` |
| VE decay | `60 / kLogicUpdateRate` per tick at 2.5 Hz = **60 VE/sec flat**, floored at 0. CE never decays. | `map_constants.h:45` |
| First engage | First actor onto an empty hate list gets **+200 CE / +900 VE** on top of the action's own value | `enmity_container.cpp` |
| Enmity range | 25.0 yalms, 28.0 for Notorious, plus both entities' `modelHitboxSize`, centre to centre. Out of range -> action contributes 0. Notorious is unobservable, so the addon assumes it and uses 28 for every mob. | `IsWithinEnmityRange`, and every other range check for the hitbox terms |
| Target selection | `HandleEnmity()` every combat tick (2.5 Hz) sets target to `argmax(CE+VE)` over **active** entries. Tie-break prefers the current battle target, on exact equality only. | `mob_controller.cpp:1496` |

Merits contribute at most +/-5 (`enmity_increase` / `enmity_decrease`, 5 ranks x 1).
The hidden scalar is therefore dominated by **gear**, which is swapped per-action
by anyone running luashitacast.

---

## 3. Horizon deltas

| Delta | Effect |
|---|---|
| **Provoke + Defender** | +250 CE if WAR main, **+180 CE** if WAR sub |
| **Defender** | `ENMITY_LOSS_REDUCTION 25%` (LSB has none) -> CE loss on damage x0.75 |
| **Sentinel** | Enmity **+100** for its 30s duration -> multiplier pinned at the 2.00x clamp. No loss reduction on Horizon. 5 min recast. |
| **Yonin** (NIN main) | Enmity **+10**; Utsusemi becomes 160 CE / 480 VE (vs 0/160) |
| **Hojo: Ni / Kurayami: Ni** | 40 CE / 450 VE - CE halved, VE doubled vs era |
| **Resting** | heals more than LSB, and the wiki says Signet "gives a bonus to HP Recovered While Healing", size unstated. Measured 2026-09-13 at 75 with 1223 max HP: 35 + 4 a tick without Signet (Al Zahbi, Sanction), 48 + 6 under Signet, against LSB's 10 + 1 and 31 + 5; the cure enmity follows. Applied unless `values` is `lsb`. Scaling with level and max HP unmeasured. |
| **Sattva Ring** | Enmity+5 (plus Horizon-custom DT-5%) |
| **Healer's Earring** | Enmity-2, **conditional on /WHM** |
| **Avatar: Enmity +/-N** gear | Evoker's -2/-3, Summoner's +1 +2 - modifies the *avatar's* own multiplier |

Wiki-confirmed as matching the era model: pull = 200 CE / 900 VE, shadow loss =
-25 CE, Provoke 1800 VE fully decayed in 30s (= 60 VE/s).

**Caveat:** the wiki states VE values are only accurate to **+/-10**. Even
"era-verified" table entries are not exact - see section 9.

The Provoke/Defender rule is absent from every other implementation
surveyed, and is worth patching in them separately.

---

## 4. Observability

**Readable:**
- `0x28` action packets - actor, target, category, param, message. The only
  unambiguous source of mob targeting; there is no memory field for it.
  (Pattern: `addons/targetlines/tracker.lua`.)
- `0x29` basic messages - deaths, misc.
- `0x076` party buffs - your own party only: the packet and `IParty`'s status
  icons hold five entries, the local player's come from `IPlayer`.
- `GetMemberMainJob` / `GetMemberSubJob` - all 18 alliance slots.
- Entity HP%, position, heading, spawn flags, server id.
- Mob level range - `addons/mobdb` imports Min/MaxLevel per zone from LSB SQL.
  Better: the server states a level in every `/check` reply (0x029, param)
  and every widescan row (0x0F4); those are kept per mob and, per zone and
  name, between sessions. Horizon's custom mobs are in the Horizon table.

**Not readable, and how it's handled:**
- Other players' MaxHP -> not needed. `dmg/maxHP` **is** the observable HP% delta.
- Mob's exact level -> nuisance variable sampled per-particle from the mobdb range.
- Enmity gear and merits -> the latent variable. This is the whole problem.
- Non-alliance players' buffs and jobs -> out of scope (section 5).

**Explicitly rejected:** `GetClaimStatus`. Claim tracks who first claimed the
mob, not who holds hate. It will confidently assert wrong constraints.

**Mob heading** is a secondary channel: the server calls
`PathFind->LookAt(target)` every tick, so the mob physically faces its target and
the client can read this at framerate. Used at much lower likelihood weight,
gated on engaged + stationary, disabled for mobs with the `NoTurn` behavior.

---

## 5. Scope

Three tiers of actor:

- **Modelled** - alliance members (18 slots) plus their pets and trusts. These get
  a latent variable, a simulated enmity entry, and a bar. Pets and trusts get a
  tight 1.0x prior and never share their master's posterior.
- **Seen** - non-alliance entities observed acting on a tracked mob. Tracked by
  name/index only. No latent, no simulation, no bar. Their sole purpose is to let
  the UI recognise that the mob is on someone unmodelled.
- **Ignored** - everything else.

Every engaged mob is tracked internally. Display shows one mob at a time with a
configurable top-N of bars.

**Why dropping outsiders is safe.** Enmity entries are per-entity and isolated.
An outsider's actions only ever touch the outsider's own CE/VE - every
cross-player mechanic in the source (Trick Attack's transfer, Cover,
Accomplice/Collaborator) is party-scoped. The only cross-effect is the
first-engage bonus, which goes to whoever pulled.

This yields a clean rule with no contamination machinery:

> A targeting observation is informative **iff the observed target is a modelled
> actor.** If the mob is on an alliance member, `argmax over everyone = X`
> implies `X > every alliance member` - exactly the constraint wanted. If the mob
> is on an unmodelled entity, the observation carries no information about
> alliance ordering: discard it.

A consequence worth noting: because every modelled actor is in your alliance,
their enmity buffs are known without inference. Your own party's are read from
`0x076`; the other parties' come from the `0x28` of the ability that granted
them, with its known duration, whenever it was used within range of you. There
is no buff-inference tier.

---

## 6. Estimator

### Latent structure

**Per player x action class**, with a shared per-player prior so thin classes
borrow strength. Classes: melee round, weaponskill, job ability, offensive magic,
cure, other - chosen to match how gearswap sets are actually built.

Observable buffs are **deterministic overlays**, not latent. The particle's bonus
is gear + merits (the genuine unknown); Sentinel +100, Yonin +10, Defender's loss
reduction and Provoke bonus, and subjob-conditional gear are added on top as
known quantities with known durations. Muted Soul is the one latent that is
conditional: a DRK main's rank, 0-5, subtracts 10 a rank inside the same clamp
only while Souleater is up, so it is carried per particle as a discrete draw and
learned from Souleater windows alone. A Sentinel window therefore *explains* a
2x spike exactly rather than confusing the filter, which makes every surrounding
observation more informative about the gear underneath.

### Machinery

**Particle filter**, ~512-1024 particles over the joint bonus vector. Each
particle carries a candidate bonus vector *and* a full CE/VE state for every
modelled actor.

- An action updates every particle in O(1) - only one actor's state changes.
- A target observation reweights particles by how well `argmax(CE+VE)` matches,
  via a **soft logistic likelihood on the enmity margin**, so a single surprising
  observation cannot collapse the filter.
- Resample only on ESS dropping below threshold, never on a schedule.

The joint representation is required because constraints couple players:
"A beat B" is not factorisable into independent per-player marginals.

VE's floor at zero makes total enmity *piecewise* linear in the bonus, so
pre-bonus sums cannot simply be dot-producted. Stateful particles are what make
the incremental update cheap despite this.

### Evidence

- `0x28` action packets - hard evidence, unambiguous and timestamped.
- Mob heading - weak corroboration, gated as described in section 4.
- **Switch instants carry the heaviest weight in both channels.** When the mob
  flips from X to Y at time *t*, Y's total *crossed* X's right then. That is a
  near-equality and far tighter than any steady-state inequality.

### Prior

Job-conditional (tanks lean positive, mages lean negative via Enmity Decrease
merits, DD near zero), overridden by per-character posteriors persisted across
sessions and decayed back toward the job prior with time since last seen.

---

## 7. Edge mechanics

Classified by observability. Everything in the first group is simulated exactly
with no added uncertainty.

### Simulate exactly

| Mechanic | Handling |
|---|---|
| **Cure fan-out** | `GenerateCureEnmity` gates on `m_HiPCLvl > 0 && HasID(cureTarget)`. Apply each cure to every tracked mob whose hate list contains the healed player. Divisor uses the **cure target's** level. Amount healed is in the packet. |
| **Resting** | `scripts/effects/healing.lua`: every `HEALING_TICK_DELAY` (10 s) tick after the first heals 10 + (tick - 2) HP, more under Signet or Sigil, then `updateEnmityFromCure(self, healHP)` on every mob holding the player, healed or not. Read from the member's entity status (33); tick the same clock from when they are seen sitting. |
| **In-range enmity** (Warcry etc.) | `GenerateInRangeEnmity` gates on `HasID(source)`. Apply to every tracked mob already hating the user. `directAction = false`. |
| **Cover** | Coverer +200 CE; covered target -10% of **both** CE and VE. It is an `if/else` at `battleutils.cpp:2248` - the coverer takes **no** normal CE loss on that hit. Easy to double-count. |
| **Issekigan** | +300 CE per parry. VE comes only from job points, so 0 in era. |
| **Killshot** | If the mob kills its current *highest*-enmity holder, that entry is `Clear()`ed outright. Killing anyone else only sets `active = false`. The distinction drives everything that happens next. |
| **Active flag** | A mob's area action that kills a secondary target deactivates them (`handleSecondaryTargetEnmity`); being reached by one while alive, or any non-negative `UpdateEnmity`, reactivates. A dead, zoned or logged-out entry is erased by `GetHighestEnmity` the moment it would be picked. `GetHighestEnmity` skips inactive entries - an inactive player with huge enmity is invisible to targeting. |
| **Pets / trusts** | Hold their own enmity entries. The master receives only `AddBaseEnmity` (a 0/0 entry putting them on the list), from a single tame-related call site. There is **no** proportional share in LSB or ASB. |

### Generated table

**Mob TP move hate resets.** 50 mobskills touch enmity; **25** are exactly
`mob:resetEnmity(target)` = `LowerEnmityByPercent(target, 100, nullptr)`, zeroing
both CE and VE for the player hit. Four more apply a partial `lowerEnmity`. All
are identified by mobskill ID in `0x28`.

Generate a **mobskill ID -> enmity effect** table with its own trust tier. This
converts the single worst filter-poisoning source into an ordinary modelled
event. Any mobskill *not* in the table followed by an unexplained switch is a
clean trigger for the surprise path (section 8) and a candidate for a new table entry.

### Nuisance variable

**Trick Attack.** `UpdateEnmityFromDamage(taChar, damage)` sends the *entire*
damage enmity to the partner, scaled by the **partner's** multiplier. The packet
does not name the partner.

Model the partner as a **per-event categorical nuisance variable**: each particle
samples a candidate from the THF's own party (TA requires same party, so the
candidate set is at most five known alliance members), weighted by how well they
line up behind the mob. Subsequent targeting evidence resolves it for free - a
particle that assigned the lump to the wrong player mispredicts the next switch
and loses weight.

### Behaviour flag

**Shadow absorb -25 CE.** Negative, so unscaled by the bonus multiplier.

The shadow count is decremented before either server tests it, so `Shadow` in
both branches below is what is *left* after the absorb.

- **ASB / era:** charged inside the `else if (Shadow < 4)` branch, so only when
  shadows remain. The absorb that eats the last shadow, `Shadow == 0`, is free.
- **LSB:** charged in the outer `if (Shadow > 0)`, above that split, so every
  absorb pays, the last shadow included.

Horizon rebased onto LSB in Jan 2026, so which is live is unknown. Ship as a
behaviour flag **defaulting to LSB**. For a tanking NIN this is -25 CE every
third or fourth absorb: small per event, systematic over a fight. Registered as
an open question (section 10).

---

## 8. Integrity and the surprise detector

Every mechanic above is a way the real container can move without the model
predicting it. The failure mode is always identical: the filter explains the
discrepancy by blaming someone's hidden gear, and a wrong posterior is worse than
a wide one.

**Surprise detector.** When incoming observations are inconsistent with
essentially all particles (ESS collapse), do **not** resample - resampling at
that moment is precisely what launders an unmodelled event into a confident wrong
belief. First ask whether the belief was too narrow: a mob choosing someone no
particle had ahead usually means the particles never tried the gear that would
explain it, not that the server did something unmodelled. So **refit**: redraw the
member attacked and the leader across the whole range the server allows (Enmity
-50 to +100, LandSandBoat's clamp), reset every particle's weight, and replay the
fight's events since its lists opened through the redrawn particles, so
everything seen counts under the wider belief. The replay runs in a fresh sim on
the same particles and its lists replace the old ones. Only when even the clamp
cannot explain the attack is it a **discontinuity**: the replayed sim re-anchors
the member, raising their entry in every particle to one above the best other
active entry, the least the real list can have held, and the list stays absolute
with that member's values a floor. Dropping the list to ordering-only instead, as
first built, left the filter blind for the rest of any fight where the
unmodelled event recurred; the 2026-09-13 Jailer of Love logs showed tanks near
+100 and rangers near -50, a combination the job priors never drew, declared as
discontinuities.

Measured on those two fights by `tools/replay.lua --filter`: refitting the pair
involved lifted the posterior's average credit to the mob's target from 74% to
78% on the first and left the second at 79%; widening everyone on the list, or
refitting on a run of unlikely attacks, did worse or was mixed, and both stay as
replay options rather than defaults.

**Two integrity tiers per mob:**

- **Clean** - engage witnessed from an empty hate list. Publish absolute CE/VE.
- **Ordering-only** - joined mid-fight. Suppress absolute values; publish rank
  ordering and deltas accumulated since watching began, visually marked as such.

---

## 9. Table trust

Generated Lua table with **per-entry trust tiers**: era-verified, LSB-default,
unknown. Era-verified treated as exact; the other tiers inject extra variance so
bands widen honestly when a fight leans on unverified actions.

Where the era table and LandSandBoat disagree (171 abilities and spells), the
table carries both values and a `values` setting picks which the sim applies:
`era` on Horizon, `lsb` against a LandSandBoat server, where the replay was
verified exact tick for tick. Horizon's own choice per entry is unknown and is
the subject of an open ticket (per-entry era-vs-LSB inference).

The era table's stated **+/-10 VE** accuracy is modelled as independent zero-mean
noise **per application**, not as a global fudge. Variance grows as sqrt(n) * 10 rather
than linearly - a fight with 200 table-driven actions carries roughly +/-140 VE of
table error, negligible against a 10000 cap.

Mob level comes from the server where it can: a `/check` reply or widescan row
states it for the mob, the highest level seen stated for that name in that zone
stands for later spawns, then Horizon's own level table, then LandSandBoat's.
Sampling the level per particle from the range and narrowing it on evidence
remains the plan for mobs no source pins.

---

## 10. Research registry

A registry of open questions about server behaviour. Each entry carries a prior,
a hypothesis set, qualifying-observation criteria, and a persisted posterior.
Server-constant parameters are shared across every character and every fight, so
they accumulate evidence far faster than per-player gear ever will.

**Live:** write a structured event log for each open question; run only the
single simplest hypothesis so bars are not nonsense.
**Offline:** a separate replay tool scores competing hypotheses against the
accumulated log. The raw log means a better model can be applied later without
re-collecting months of data.

Local only. No export path.

### Entry 1 - Summoner avatar enmity share

Horizon grants summoners a percentage of the enmity their avatars generate.
**LSB and ASB have no proportional share whatsoever** - the master receives only
a 0/0 base entry. The wiki does not document it, and no implementation
surveyed has modelled it. This
is genuinely uncatalogued.

Confounded with **"Avatar: Enmity +/-N"** gear, which modifies the avatar's own
multiplier. The confound breaks because avatars hold hate in their own right:

- mob targets the **avatar** -> constrains the avatar's own enmity
- mob targets the **summoner** -> constrains `k * (avatar enmity)`

Two observation types, two equations, both unknowns recoverable. This is why
pets and trusts are first-class modelled actors.

Summoners are often otherwise idle between Blood Pacts, so their enmity is
nearly all pet-derived - an unusually clean natural experiment.

**The functional form is unknown, not just the value.** Hypotheses:

- share applies to CE, to VE, or to both
- everything the avatar generates, or Blood Pacts only
- per-action at generation, or periodic transfer
- taken before or after the avatar's own Enmity+/- multiplier

The CE/VE question separates almost immediately: **VE decays at 60/s and CE does
not**, so the two produce visibly different summoner decay curves within seconds
of a Blood Pact. The decay signature is the best discriminator and it is free.

### Entry 2 - Shadow absorb rule

Binary: LSB behaviour (every absorb) vs era behaviour (only when shadows remain).
Directly testable in game by watching hate across a NIN's final shadow.

---

## 11. Interface

**Focus.** Follows your current target. No target, or target not engaged -> fall
back to the mob the most alliance members are hitting. Pin command locks focus.
Panel appears when something is engaged and hides itself when nothing is.
Position remembered globally, not per character.

**Bar scale.** Full width = **20000** (10000 CE + 10000 VE). CE pinning at its cap
is visible as a hard wall - the era dynamic where VE alone decides the target. A
vertical marker sits at the leader's total.

**Bar anatomy.** Colour-coded CE and VE segments summing to the total. Opaque out
to the lower credible bound. Beyond it, alpha falls off in proportion to the
posterior's tail, fading to nothing at the upper bound - the translucent region
*is* the distribution. A 1px tick marks the median. As the filter converges the
ramp collapses toward the tick.

**Unmodelled hate holder.** A row at the top naming the entity that actually
holds hate, drawn without a bar or band so it reads as not-an-estimate. Alliance
bars continue below - that ordering is still correct and still useful - but the
leader marker is **hidden**, because it would be false.

---

## 12. Engineering

**Rendering.** ImGui draw list as a bare canvas - `GetBackgroundDrawList` or a
chromeless window, everything via `AddRectFilled`, `AddRectFilledMultiColor` and
`AddText`, with custom TTF atlas fonts. No widgets, no window frame, no default
styling; correct compositing, per-vertex alpha, clipping and hit-testing retained.
`AddRectFilledMultiColor` provides the alpha ramp as a four-corner vertex
gradient - no baked textures needed. The settings panel may use real widgets.

**Performance.** State in flat FFI int32 arrays, zero per-frame allocation so the
Lua GC never spikes mid-fight. Particles update only on action packets and the
2.5 Hz tick, never per frame. ESS-triggered resampling. Self-measured frame cost
with automatic particle-count scaling to stay inside a hard ~0.5 ms budget.
Render reads the last committed estimate and interpolates.

**Data.** Vendored, self-contained tables. Generator script lives in this repo
with a provenance header per entry so regeneration is reproducible rather than
archaeological. Drift from upstream sources is a known accepted cost.

**Storage.** Local only, under `Ashita/config/addons/enmetry`, keyed by server +
character name, plaintext so it can be inspected and corrected. Never
transmitted, no export format. `/enmetry forget <name>` and a blanket purge.

---

## 13. Validation

- **Live:** held-out predictive accuracy. Before each observed target switch,
  record what the filter predicted, then score it. Needs no ground truth and
  surfaces as a calibration readout - if the 80% band contains the truth 80% of
  the time, the estimator is honest.
  As built, the truth an attack reveals is who held hate, so what is scored is
  the 80% credible set over who holds hate, its edge counted fractionally so
  an honest posterior earns exactly 80%. Every attack the filter judges is
  scored, since keeping only those that turned out to be switches selects on
  the outcome and biases even an honest posterior; attacks where no entry was
  80% likely beforehand are reported apart as the contested subset.
- **Dev:** this repo's tests, against values worked independently from
  LandSandBoat's source, and checks in game. The addon is standalone: nothing
  outside this repo is built, run or changed to validate it.

**Open measurements** (things assumed, not verified):

1. Does Horizon use the 10000 era cap, or LSB's configurable default?
   Detectable: a tank's CE visibly stops rising despite continued
   enmity-positive actions.
2. Shadow absorb: LSB or era rule? (section 7)
3. Summoner avatar enmity share: value and functional form. (section 10)

---

## 14. Build order

1. **Deterministic sim.** Replay engine with bonuses fixed at the prior and no
   uncertainty at all: bars, CE/VE split, cap line.
2. **Verify** it in game and against the tests' source-derived values.
3. **Particle filter.**
4. **Alpha ramp.**

Everything downstream sits on the sim being right. A beautiful confidence band
over a wrong simulation is worse than no addon, and you would never know.
