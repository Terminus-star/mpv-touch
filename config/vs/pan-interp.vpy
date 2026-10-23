# pan-interp: soften the stepping of fast camera moves without touching the animation.
#
# Used as an mpv filter (needs a VapourSynth-enabled mpv, such as cachyos/mpv-git):
#     mpv --vf=vapoursynth=file=~~/vs/pan-interp.vpy:user-data=mix-high video.mkv
#
# Idea: a fast pan shown at 23.976 fps jumps many pixels per frame and looks like it strobes.
# A film camera hides this with motion blur (the shutter is open while the picture moves). The
# first version of this filter inserted full in-between frames, which made pans run at 48 fps
# inside a 24 fps episode: smooth, but unnaturally so. Later versions only blurred, but blur only
# softens the steps and an in-between frame is what shrinks them, so the blur-only levels were
# dropped as not enough. Every level now adds an in-between frame inside a camera move, from a
# weak blended one (mix-high) up to the full halfway frame (double).
#
#   * Inside a detected camera move the output has twice the frame rate; everywhere else each
#     real frame is followed by an exact repeat, so the cadence stays even.
#   * Real frames inside a move are blurred along their own motion vectors (MVTools FlowBlur), as
#     a shutter would, except in `double`. Everything outside a move passes through untouched.
#   * The blur scales with the speed of the move: a move only just over the detection
#     threshold gets half of the chosen strength, a very fast one gets all of it.
#   * Pans are detected on a half-resolution copy of the luma plane: a pan moves most of the
#     picture, character animation moves only a small part of it.
#   * The expensive full-resolution work is only computed for frames inside a camera move.
#   * Pans drawn on twos or threes (each drawing shown for 2 or 3 frames, so the picture jumps once
#     every 2 or 3 frames) are found too, and their repeated frames are replaced by frames
#     interpolated between the drawings, whatever the level (true positions, as in `double`; the
#     real frames are not blurred there). Fades through black or white and cuts are not pans.
#
# Strength (the "slider"): mpv passes the text after `user-data=` in as `user_data`.
#     off       the filter passes the video through unchanged
#     mix-high  shutter 50 % (a 180 degree film shutter), plus an in-between frame that is 50 %
#               halfway frame blended with the real one (a cross-fade; the default when nothing is given)
#     mix-max   the same, with 70 % halfway frame
#     step      shutter 50 %, plus an in-between frame interpolated 35 % of the way to the next
#               frame, not blended, so lines move instead of doubling
#     step-adaptive  the same, but the distance follows the speed of the move: 20 % for a move
#               just over the detection bar, 30 % for a middling one, 40 % for a fast one
#     double    frame doubling: no blur, and the in-between frame is the full halfway frame (50 % of
#               the way, motion-interpolated, not blended): the most "48 fps" looking single level;
#               for scenes where the others are not enough
#     mix-step  combination: the in-between frame is the equal average of the mix-high and the step
#               in-between frames (real frames blurred at 50 %)
#     mix-step-double  combination of mix-high, step and double: the equal average of all three
#               in-between frames. The combinations cost about 1.45x the CPU of mix-high (they
#               interpolate two frames per move; the 50 % frame is shared, so three members cost
#               the same as two; measured at 720p).
# scripts/pan-blur.lua cycles these with Ctrl+p. A running VapourSynth script cannot be changed,
# so changing the level re-adds the filter, which restarts it for a moment.
#
# Frame rates of 40 fps or more pass through unchanged.
#
# Tuning (environment variables, read when the script loads):
#   PAN_MOTION  mean motion needed, 0..1 of PAN_ML (default 0.40, about 6.4 px per frame at 1080p)
#   PAN_FULL    mean motion at which the full strength is reached (default 0.90)
#   PAN_BAD     largest share of the picture a camera move may leave unexplained (default 0.02)
#   PAN_FADE    change of the average brightness over a pair, as a share, that counts towards a fade
#               (default 0.05); PAN_FADE_PAIRS how many pairs of the window must change the same way
#               for it to be a fade and not a camera move (default 6); PAN_CUT a single pair changing
#               by more than this share is a cut (default 0.15)
#   PAN_COVER   share of the picture that must be moving, 0..1 (default 0.60)
#   PAN_DUP     a pair with less mean motion than this is a repeated frame and, next to a camera-move
#               pair, counts as a yes vote, so pans animated on twos are found (default 0.03)
#   PAN_MIN_PX  a block counts as moving above this many half-resolution pixels (default 2)
#   PAN_ML      motion that counts as "full" in the mask, half-resolution pixels (default 8)
#   MVTOOLS_PLUGIN  path to mvtools.so, only needed if it is not installed system-wide
import os
from fractions import Fraction

import vapoursynth as vs

core = vs.core


def env_float(name, default):
    return float(os.environ.get(name, default))


if not hasattr(core, 'mv'):
    plugin = os.environ.get('MVTOOLS_PLUGIN')
    if plugin:
        core.std.LoadPlugin(plugin)
mv = core.mv  # fails with a clear error when MVTools is missing

# 0.40 of 8 half-resolution pixels is about 6.4 px per frame at 1080p: real pans and fast moves.
# (0.20 also caught slow push-ins and drifts behind dialogue, where it warped the characters.)
MIN_MOTION = env_float('PAN_MOTION', 0.40)
FULL_MOTION = env_float('PAN_FULL', 0.90)
MIN_COVER = env_float('PAN_COVER', 0.60)
MIN_PX = env_float('PAN_MIN_PX', 2)
ML = env_float('PAN_ML', 8)
# a pixel counts as "badly explained" when the rebuilt frame is off by more than this share of
# the brightness range, and the pair is not a clean camera move when more than MAX_BAD of the
# picture is (dissolves, a character changing pose)
PIX_ERR = env_float('PAN_PIX_ERR', 0.08)
# (0.01 missed a real fast pan drawn on twos/threes, whose pairs leave 1-3 % unexplained; 0.03 let a
# close-up of a character turning its head through; 0.02 caught the pan and passed only 1 frame of it)
MAX_BAD = env_float('PAN_BAD', 0.02)
# A pair whose mean motion is below this is a repeated frame ("animated on twos": every drawing is
# shown for two frames, so a pan alternates between a jump and a repeat). Repeats do not vote
# against a pan, see `decide`.
DUP_MOTION = env_float('PAN_DUP', 0.03)
# A fade is the average luma moving the SAME way by more than MAX_FADE per pair, for FADE_PAIRS
# or more of the pairs in the vote window (a fade through black measured 9-78 % per frame over 8-14
# pairs in a row; real pans under 1 %). One bright object or a flash gives only a pair or two, so
# it is not a fade. A single pair changing by more than MAX_CUT is a cut, never a camera move.
MAX_FADE = env_float('PAN_FADE', 0.05)
FADE_PAIRS = int(env_float('PAN_FADE_PAIRS', 6))
MAX_CUT = env_float('PAN_CUT', 0.15)
# Quality of the full-resolution vectors. These decide almost all of the CPU cost.
PEL = int(env_float('PAN_PEL', 1))      # 1 = whole-pixel search, 2 = half-pixel (4x the data)
BLOCK = int(env_float('PAN_BLOCK', 32))  # block size in pixels (16, 32, 64); overlap is half of it

# per level: (shutter as a percentage of the frame time (FlowBlur's `blur`),
#             share of the halfway frame blended into the in-between frame,
#             how far toward the next frame the in-between frame is interpolated, in percent)
# (A shutter of 0 means no blur. Every level has one of the last two fields set, so the output
# has twice the frame rate, and after each real frame comes either
#   * a blend of that frame and the halfway frame (a cross-fade: moving edges show up twice), or
#   * a frame interpolated along the motion to a fraction of the way (lines move, so no ghosting,
#     but a step under 50 % makes the spacing in time slightly uneven; exactly 50 % is even).
LEVELS = {
    'mix-high': (50.0, 0.5, 0),
    'mix-max': (50.0, 0.7, 0),
    'step': (50.0, 0.0, 35),
    # the last field may also be three distances, for a slow, middling and fast move
    'step-adaptive': (50.0, 0.0, (20, 30, 40)),
    # frame doubling: no blur, and the in-between frame is the full halfway frame (the 48 fps look)
    'double': (0.0, 0.0, 50),
}
# Combinations: the in-between frame is the EQUAL AVERAGE of the named levels' in-between frames
# (so `mix-step` is half the mix-high frame and half the step frame). The real frames are blurred
# with COMBO_SHUTTER, the shutter shared by mix-high and step. A combination needs the work of all its
# members, so it costs more CPU than a single level (interpolated frames are shared, see `interpolated`).
COMBOS = {
    'mix-step': ('mix-high', 'step'),
    'mix-step-double': ('mix-high', 'step', 'double'),
}
COMBO_SHUTTER = 50.0
# share of that shutter used for a slow, middling and fast move. Whole-pixel vectors round a
# blur under about one pixel to nothing, so the weakest step must stay large enough to show.
SHARES = (0.5, 0.75, 1.0)
level = str(globals().get('user_data', '')).strip().lower() or 'mix-high'  # noqa: F821
if level != 'off' and level not in LEVELS and level not in COMBOS:
    raise ValueError(f'pan-interp: unknown level {level!r}, use off or one of '
                     f'{", ".join(list(LEVELS) + list(COMBOS))}')

# The levels that interpolate an in-between frame along the motion (`step`, `step-adaptive`, `double`,
# and every combination, which contains one) move lines to a new position, so a wrong vector shows as
# a doubled line. With 32 px blocks, thin lines that repeat (fences, blinds, bricks) matched badly in
# a test and each vertical line appeared twice; 16 px blocks fixed it. Only those levels pay the cost.
if (level in COMBOS or LEVELS.get(level, (0, 0, 0))[2]) and 'PAN_BLOCK' not in os.environ:
    BLOCK = 16

src = video_in  # noqa: F821  (defined by mpv)

if level == 'off' or container_fps >= 40 or container_fps <= 0:  # noqa: F821
    src.set_output()
else:
    # ---- pan detection, on half-resolution luma ----
    y = core.std.ShufflePlanes(src, 0, vs.GRAY)
    width = max(32, (y.width // 2) // 16 * 16)
    height = max(32, (y.height // 2) // 16 * 16)
    small = core.resize.Bilinear(y, width, height)

    sup_small = mv.Super(small, pel=1, hpad=8, vpad=8)
    fwd_small = mv.Analyse(sup_small, isb=False, blksize=16, overlap=0, search=4, truemotion=True)
    mask = mv.Mask(small, fwd_small, ml=ML, kind=0)
    # How well does one camera motion explain the change to the next frame? Rebuild the frame
    # from its neighbour along the vectors and count how much of the picture is still wrong.
    # A real camera move rebuilds almost perfectly; a dissolve, or a character changing pose,
    # leaves patches behind. (A whole-frame average hides small patches, so count pixels.)
    rebuilt = mv.Compensate(small, sup_small, fwd_small)
    miss = core.std.Expr([small, rebuilt], 'x y - abs')
    miss_top = (1 << miss.format.bits_per_sample) - 1
    unexplained = core.std.PlaneStats(core.std.Binarize(miss, threshold=int(miss_top * PIX_ERR)))

    top = (1 << mask.format.bits_per_sample) - 1
    moving = core.std.Binarize(mask, threshold=int(top * min(1.0, MIN_PX / ML)))
    mean_motion = core.std.PlaneStats(mask)      # PlaneStatsAverage: mean motion, 0..1
    covered = core.std.PlaneStats(moving)        # PlaneStatsAverage: share of moving area
    # average luma of each frame, and of the next one (the last frame is repeated), so a pair can
    # tell whether the picture is getting brighter or darker (a fade), which a camera move does not do
    luma = core.std.PlaneStats(small, prop='Luma')
    luma_next = core.std.Trim(core.std.DuplicateFrames(luma, [luma.num_frames - 1]), first=1)
    # ---- full-resolution blur along the motion, evaluated only when asked for ----
    # Three strengths (SHARES of the chosen level) so the blur can follow the speed of the move.
    # FrameEval is lazy: only the clip that is returned gets computed.
    sup_full = mv.Super(src, pel=PEL)
    back = mv.Analyse(sup_full, isb=True, blksize=BLOCK, overlap=BLOCK // 2, search=4, truemotion=True)
    fwd = mv.Analyse(sup_full, isb=False, blksize=BLOCK, overlap=BLOCK // 2, search=4, truemotion=True)
    # a combination blurs its real frames with COMBO_SHUTTER; a single level uses its own shutter
    shutter = COMBO_SHUTTER if level in COMBOS else LEVELS[level][0]
    if shutter > 0:
        blurred = [mv.FlowBlur(src, sup_full, back, fwd, blur=shutter * share)
                   for share in SHARES]
    else:
        blurred = [src] * len(SHARES)   # no blur (frame doubling): the real frames stay untouched

    # A motion-interpolated frame t % of the way to the next one, built once however many levels use
    # it (mix-high and double both use 50 %). It is not blurred: a blur would soften moved lines.
    interpolated_cache = {}

    def interpolated(t):
        if t not in interpolated_cache:
            interpolated_cache[t] = mv.FlowInter(src, sup_full, back, fwd, time=t, blend=True)
        return interpolated_cache[t]

    def in_between(name):
        """The in-between frame of one level, for a slow, middling and fast move."""
        _, mix, step_time = LEVELS[name]
        if mix > 0:
            # the blurred real frame with a share of the halfway frame mixed in (a cross-fade)
            return [core.std.Merge(clip, interpolated(50), weight=mix) for clip in blurred]
        # one distance for every speed, or one per speed band (slow, middling, fast)
        times = tuple(step_time) if isinstance(step_time, tuple) else (step_time,) * len(SHARES)
        return [interpolated(t) for t in times]

    # FrameEval is lazy, so only the clip that is returned for a frame is ever computed.
    members = [in_between(name) for name in COMBOS.get(level, (level,))]
    mixed = []
    for band in range(len(SHARES)):
        clip = members[0][band]
        for count, other in enumerate(members[1:], start=2):
            # running mean: the count-th member gets weight 1/count, so all members end up equal
            clip = core.std.Merge(clip, other[band], weight=1.0 / count)
        mixed.append(clip)

    log_path = os.environ.get('PAN_LOG')  # optional: one line per frame, for tuning

    # ---- decide per pair, then smooth the decision with a vote over the neighbouring pairs ----
    HALF = int(env_float('PAN_SMOOTH', 5))   # pairs looked at on each side
    VOTES = int(env_float('PAN_VOTES', 7))   # yes votes needed out of 2 * HALF + 1

    def judge(n, f):
        motion = f[0].props['PlaneStatsAverage']
        out_frame = f[0].copy()
        # signed relative change of the average luma over the pair; the floor stops a black frame
        # from dividing by zero (a fade from or to black changes by a large share of a tiny value)
        before, after = f[3].props['LumaAverage'], f[4].props['LumaAverage']
        fade = (after - before) / max(before, after, 0.004)
        out_frame.props['PanRaw'] = int(motion >= MIN_MOTION
                                        and f[1].props['PlaneStatsAverage'] >= MIN_COVER
                                        and f[2].props['PlaneStatsAverage'] <= MAX_BAD
                                        and abs(fade) <= MAX_CUT)
        out_frame.props['PanFade'] = fade
        out_frame.props['PanMotion'] = motion
        out_frame.props['PanDup'] = int(motion < DUP_MOTION)
        out_frame.props['PanBad'] = f[2].props['PlaneStatsAverage']
        return out_frame

    judged = core.std.ModifyFrame(mean_motion, [mean_motion, covered, unexplained, luma, luma_next], judge)

    def shifted(clip, k):  # the frame at position n shows pair n + k
        if k > 0:
            return core.std.Trim(clip, first=k)
        if k < 0:
            return core.std.DuplicateFrames(clip, [0] * -k)
        return clip

    window = [shifted(judged, k) for k in range(-HALF, HALF + 1)]

    # ---- pans drawn on twos or threes: re-time the held frames ----
    # A pan whose drawings are each shown for L frames (A A B B on twos) jumps once every L frames.
    # Interpolating between two identical frames cannot soften that, so inside such a "held run"
    # the repeats are replaced: starting from the run's first frame A, the output slots (two per
    # source frame) are A, then frames 1/(2L), 2/(2L), ... of the way to the next drawing B, found
    # with MVTools vectors that span L frames (delta = L). Only runs of 2 or 3 frames are handled.
    # The vectors and the frames built from them are only computed for frames that fall in such a run.
    HOLDS = (2, 3)
    # Everything is built now, when the script loads: MVTools reads frame 0 when an Analyse is made,
    # and mpv no longer has it once playback is under way (a first version that built these on demand
    # stopped the video at the first held run in a real episode). Building is cheap; a clip only
    # does work when a frame of it is asked for.
    hold_cache = {}
    for length in HOLDS:
        back_l, fwd_l = (mv.Analyse(sup_full, isb=isb, blksize=BLOCK, overlap=BLOCK // 2, search=4,
                                    truemotion=True, delta=length) for isb in (True, False))
        for slot in range(1, 2 * length):
            built = mv.FlowInter(src, sup_full, back_l, fwd_l, time=100.0 * slot / (2 * length), blend=True)
            # built at the run's first frame; the source frame `slot // 2` frames into the run shows it
            hold_cache[(length, slot)] = shifted(built, -(slot // 2))

    def hold_inter(length, slot):
        """The frame for output slot `slot` (1 .. 2 * length - 1) of a held run of `length` frames
        (slot 0 is the run's first frame, which stays the real frame)."""
        return hold_cache[(length, slot)]

    def hold_info(f):
        """(length, position) of the held run the middle frame of the window belongs to, or None.
        A held run is frames shown identically (pairs flagged PanDup) that sit between two pairs that
        are camera moves, so the run has a first frame, a last frame, and a move on each side."""
        dup = [frame.props['PanDup'] for frame in f]
        raw = [frame.props['PanRaw'] for frame in f]
        first = HALF
        while first > 0 and dup[first - 1]:
            first -= 1
        last = HALF
        while last < len(f) and dup[last]:
            last += 1
        # `first - 1` is the pair before the run, `last` the pair after it: both must be moves
        if first < 1 or last >= len(f) or not (raw[first - 1] and raw[last]):
            return None
        length = last - first + 1
        return (length, HALF - first) if length in HOLDS else None

    def decide(f):
        raw = [frame.props['PanRaw'] for frame in f]
        dup = [frame.props['PanDup'] for frame in f]
        # A run of repeated pairs that touches a pair that is a camera move counts as yes too: a pan
        # drawn on twos or threes goes jump, repeat (repeat), jump, repeat (repeat). Only runs short
        # enough to be one held drawing count (one repeat for twos, two for threes), so a static scene
        # next to a pan counts for nothing and a static scene alone has no jump to touch.
        counted = [bool(r) for r in raw]
        i = 0
        while i < len(f):
            if not dup[i]:
                i += 1
                continue
            j = i
            while j < len(f) and dup[j]:
                j += 1
            if j - i <= max(HOLDS) - 1 and ((i > 0 and raw[i - 1]) or (j < len(f) and raw[j])):
                counted[i:j] = [True] * (j - i)
            i = j
        votes = sum(counted)
        # a fade through black or white: the brightness moves the same way for many pairs in a row
        fades = [frame.props['PanFade'] for frame in f]
        fading = max(sum(d > MAX_FADE for d in fades), sum(d < -MAX_FADE for d in fades)) >= FADE_PAIRS
        pan = votes >= VOTES and not fading
        # speed over the whole window, so the strength does not jump between neighbours; repeated
        # pairs are left out, or a pan on twos would measure half its real speed
        moves = [frame.props['PanMotion'] for frame, d in zip(f, dup) if not d]
        speed = sum(moves) / len(moves) if moves else 0.0
        fraction = (speed - MIN_MOTION) / max(1e-6, FULL_MOTION - MIN_MOTION)
        step = 0 if fraction < 1 / 3 else 1 if fraction < 2 / 3 else 2
        return pan, step, votes

    def choose(n, f):
        pan, step, votes = decide(f)
        hold = hold_info(f) if pan else None
        if log_path:
            with open(log_path, 'a') as log:
                log.write(f'{n},{int(pan)},{f[HALF].props["PanRaw"]},{votes},'
                          f'{f[HALF].props["PanMotion"]:.3f},{step},{f[HALF].props["PanBad"]:.4f},'
                          f'{f[HALF].props["PanFade"]:.4f},{hold[0] if hold else 0},{hold[1] if hold else 0}\n')
        if hold:
            length, position = hold
            # the first frame of a run stays the real frame; the repeats are replaced
            return src if position == 0 else hold_inter(length, 2 * position)
        return blurred[step] if pan else src

    out = core.std.FrameEval(src, choose, prop_src=window)

    # mpv takes timing from the per-frame duration properties. MVTools reads frames while the
    # script loads, and mpv answers those reads with dummy frames of duration 0 that then leak
    # into the output, so the video would run ahead of the audio. Set every duration explicitly.
    fps = Fraction(container_fps).limit_denominator(1001)  # noqa: F821

    # twice the frame rate: after each real frame comes the in-between frame inside a move, or an
    # exact repeat of the real frame everywhere else, so the cadence stays even
    def choose_between(n, f):
        pan, step, _ = decide(f)
        hold = hold_info(f) if pan else None
        if hold:
            length, position = hold
            return hold_inter(length, 2 * position + 1)
        return mixed[step] if pan else src

    between = core.std.FrameEval(src, choose_between, prop_src=window)
    out = core.std.Interleave([out, between])
    out = core.std.AssumeFPS(out, fpsnum=2 * fps.numerator, fpsden=fps.denominator)
    out = core.std.SetFrameProps(out, _DurationNum=fps.denominator, _DurationDen=2 * fps.numerator)
    out.set_output()
