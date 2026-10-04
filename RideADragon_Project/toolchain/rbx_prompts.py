"""ProximityPrompt simulation: shows/hides prompts per client based on character distance."""
from luau_interp import LuaThread
import luau_interp as LI


def _prompt_pos(sim, prompt):
    from rbx_api import part_cframe, attachment_world_cf
    p = prompt.parent
    if p is None:
        return None
    if p.is_a("BasePart"):
        return part_cframe(sim, p).pos()
    if p.cls.name in ("Attachment", "Bone"):
        return attachment_world_cf(sim, p).pos()
    if p.is_a("Model"):
        from rbx_api import get_pivot
        return get_pivot(sim, p).pos()
    return None


def update(sim, dt):
    pps = sim.services["ProximityPromptService"]
    prompts = [d for d in sim.services["Workspace"].descendants() if d.cls.name == "ProximityPrompt"]
    for c in sim.clients:
        shown = c.__dict__.setdefault("shown_prompts", set())
        ch = c.player.props.get("Character")
        hrp = ch.find_child("HumanoidRootPart") if ch is not None else None
        from rbx_api import part_cframe
        cpos = part_cframe(sim, hrp).pos() if hrp is not None else None
        now = set()
        if cpos is not None:
            for pr in prompts:
                if not pr.get_prop("Enabled"):
                    continue
                pos = _prompt_pos(sim, pr)
                if pos is None:
                    continue
                if (pos - cpos).mag() <= pr.get_prop("MaxActivationDistance"):
                    now.add(pr)
        for pr in now - shown:
            pr.get_signal("PromptShown").fire(LI_enum("ProximityPromptInputType", "Keyboard"), ctx_filter=lambda x, c=c: x is c)
            pps.get_signal("PromptShown").fire(pr, LI_enum("ProximityPromptInputType", "Keyboard"), ctx_filter=lambda x, c=c: x is c)
        for pr in shown - now:
            pr.get_signal("PromptHidden").fire(ctx_filter=lambda x, c=c: x is c)
            pps.get_signal("PromptHidden").fire(pr, ctx_filter=lambda x, c=c: x is c)
        c.shown_prompts = now
        # holds
        holds = c.__dict__.setdefault("prompt_holds", {})
        for pr, t0 in list(holds.items()):
            if pr not in now:
                del holds[pr]
                continue
            if sim.sched.clock - t0 >= pr.get_prop("HoldDuration"):
                del holds[pr]
                _trigger(sim, pr, c)


def LI_enum(e, n):
    from rbx_types import E
    return E(e, n)


def _trigger(sim, pr, c):
    pps = sim.services["ProximityPromptService"]
    player = c.player
    # client-side & server-side Triggered
    pr.get_signal("Triggered").fire(player)
    pps.get_signal("PromptTriggered").fire(pr, player)
    pr.get_signal("TriggerEnded").fire(player)


def prompt_hold_begin(sim, pr, ctx):
    if ctx.kind != "client":
        return
    if pr.get_prop("HoldDuration") <= 0:
        _trigger(sim, pr, ctx)
        return
    ctx.__dict__.setdefault("prompt_holds", {})[pr] = sim.sched.clock
    pr.get_signal("PromptButtonHoldBegan").fire(ctx.player)


def prompt_hold_end(sim, pr, ctx):
    holds = ctx.__dict__.setdefault("prompt_holds", {})
    if pr in holds:
        del holds[pr]
        pr.get_signal("PromptButtonHoldEnded").fire(ctx.player)
