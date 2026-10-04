"""Static checks for Luau sources:
 - syntax (parser)
 - undefined globals / implicit global assignment
 - unused locals (warning)
 - Enum.X.Y validity, Instance.new class validity, GetService name validity
"""
import os
import sys
import difflib

from luau_parser import parse, ParseError
from luau_lexer import LexError
from rbx_enums import ENUMS

ROBLOX_GLOBALS = {
    # Lua / Luau
    "assert", "error", "getmetatable", "setmetatable", "ipairs", "pairs", "next", "pcall",
    "xpcall", "print", "rawequal", "rawget", "rawset", "rawlen", "select", "tonumber",
    "tostring", "type", "typeof", "unpack", "require", "warn", "newproxy", "gcinfo",
    "math", "string", "table", "coroutine", "os", "utf8", "bit32", "debug", "buffer", "vector",
    "_G", "_VERSION",
    # Roblox
    "game", "workspace", "script", "plugin", "shared", "task", "tick", "time", "elapsedTime",
    "wait", "delay", "spawn", "settings", "UserSettings", "version", "Enum", "Instance",
    "Vector3", "Vector2", "Vector3int16", "Vector2int16", "CFrame", "Color3", "BrickColor",
    "UDim", "UDim2", "Rect", "Ray", "Region3", "Region3int16", "NumberRange", "NumberSequence",
    "NumberSequenceKeypoint", "ColorSequence", "ColorSequenceKeypoint", "TweenInfo",
    "PhysicalProperties", "RaycastParams", "OverlapParams", "Random", "DateTime", "Font",
    "Faces", "Axes", "PathWaypoint", "SharedTable", "Content", "CatalogSearchParams",
    "FloatCurveKey", "RotationCurveKey", "DockWidgetPluginGuiInfo", "Path2DControlPoint",
}

# Classes creatable with Instance.new that we allow.
CREATABLE = {
    "Folder", "Model", "Part", "WedgePart", "CornerWedgePart", "MeshPart", "TrussPart", "Seat",
    "VehicleSeat", "SpawnLocation", "Attachment", "Bone", "Motor6D", "Weld", "WeldConstraint",
    "NoCollisionConstraint", "LinearVelocity", "AngularVelocity", "AlignOrientation",
    "AlignPosition", "VectorForce", "Torque", "BodyVelocity", "BodyGyro", "BodyPosition",
    "RopeConstraint", "SpringConstraint", "SpecialMesh", "BlockMesh", "CylinderMesh",
    "Decal", "Texture", "SurfaceAppearance", "PointLight", "SpotLight", "SurfaceLight",
    "ParticleEmitter", "Beam", "Trail", "Fire", "Smoke", "Sparkles", "Highlight", "SelectionBox",
    "Sound", "SoundGroup", "ReverbSoundEffect", "EqualizerSoundEffect", "ChorusSoundEffect",
    "PitchShiftSoundEffect", "CompressorSoundEffect", "ProximityPrompt", "ClickDetector",
    "Camera", "WorldModel", "Humanoid", "Animator", "Animation", "AnimationController",
    "StringValue", "IntValue", "NumberValue", "BoolValue", "ObjectValue", "CFrameValue",
    "Vector3Value", "Color3Value", "BindableEvent", "BindableFunction", "RemoteEvent",
    "RemoteFunction", "UnreliableRemoteEvent", "Configuration", "ScreenGui", "BillboardGui",
    "SurfaceGui", "Frame", "TextLabel", "TextButton", "TextBox", "ImageLabel", "ImageButton",
    "ScrollingFrame", "ViewportFrame", "CanvasGroup", "VideoFrame", "UICorner", "UIStroke",
    "UIGradient", "UIPadding", "UIListLayout", "UIGridLayout", "UIPageLayout", "UITableLayout",
    "UIScale", "UIAspectRatioConstraint", "UISizeConstraint", "UITextSizeConstraint",
    "UIFlexItem", "Atmosphere", "Sky", "Clouds", "BloomEffect", "BlurEffect",
    "ColorCorrectionEffect", "SunRaysEffect", "DepthOfFieldEffect", "Explosion",
    "ModuleScript", "Script", "LocalScript", "Tool", "Accessory", "Hat", "Shirt", "Pants",
    "BodyColors", "PathfindingModifier", "PathfindingLink", "Wire", "AudioPlayer",
    "AudioEmitter", "AudioListener", "AudioDeviceOutput", "AudioReverb", "AudioEqualizer",
    "AudioFilter", "Dialog", "DialogChoice", "Light", "HingeConstraint", "BallSocketConstraint",
    "PrismaticConstraint", "CylindricalConstraint", "Plane", "PlaneConstraint", "LineForce",
    "WrapLayer", "WrapTarget", "ImageHandleAdornment", "BoxHandleAdornment",
    "SphereHandleAdornment", "CylinderHandleAdornment", "ConeHandleAdornment",
    "LineHandleAdornment", "SelectionSphere", "TextChatCommand", "TextChatMessageProperties",
}

SERVICES = {
    "Players", "Workspace", "ReplicatedStorage", "ReplicatedFirst", "ServerStorage",
    "ServerScriptService", "StarterGui", "StarterPack", "StarterPlayer", "Lighting",
    "SoundService", "RunService", "UserInputService", "ContextActionService", "TweenService",
    "HttpService", "DataStoreService", "MessagingService", "MarketplaceService",
    "TeleportService", "CollectionService", "PhysicsService", "PathfindingService",
    "ProximityPromptService", "GuiService", "TextService", "ContentProvider", "Debris",
    "BadgeService", "Chat", "TextChatService", "LocalizationService", "PolicyService",
    "SocialService", "AvatarEditorService", "GroupService", "AssetService", "HapticService",
    "VRService", "StarterPlayerScripts", "LogService", "Stats", "MemoryStoreService",
    "AnalyticsService", "ScriptContext", "Teams", "VoiceChatService", "CaptureService",
    "ExperienceNotificationService", "GamepadService", "MaterialService", "TestService",
    "ChangeHistoryService", "Selection", "CoreGui",
}


class Scope:
    __slots__ = ("vars", "parent", "is_func")

    def __init__(self, parent, is_func=False):
        self.vars = {}
        self.parent = parent
        self.is_func = is_func


class Linter:
    def __init__(self, path, src):
        self.path = path
        self.src = src
        self.errors = []
        self.warnings = []
        self.scope = None

    def err(self, line, msg):
        self.errors.append(f"{self.path}:{line}: error: {msg}")

    def warn(self, line, msg):
        self.warnings.append(f"{self.path}:{line}: warning: {msg}")

    def push(self, is_func=False):
        self.scope = Scope(self.scope, is_func)

    def pop(self):
        sc = self.scope
        for name, info in sc.vars.items():
            line, used = info
            if not used and not name.startswith("_") and name != "self" and name != "...":
                self.warn(line, f"unused local '{name}'")
        self.scope = sc.parent

    def declare(self, name, line):
        old = self.scope.vars.get(name)
        if old is not None and not old[1] and not name.startswith("_"):
            self.warn(old[0], f"local '{name}' is shadowed before use (line {line})")
        self.scope.vars[name] = [line, False]

    def use(self, name, line):
        sc = self.scope
        while sc is not None:
            v = sc.vars.get(name)
            if v is not None:
                v[1] = True
                return True
            sc = sc.parent
        if name not in ROBLOX_GLOBALS:
            self.err(line, f"unknown global '{name}'")
        return False

    def is_local(self, name):
        sc = self.scope
        while sc is not None:
            if name in sc.vars:
                return True
            sc = sc.parent
        return False

    # -------------------------------------------------------------- walk
    def run(self):
        try:
            ast = parse(self.src, self.path)
        except (ParseError, LexError) as e:
            self.errors.append(str(e))
            return
        self.push(True)
        self.block(ast[2])
        self.pop()

    def block(self, stats):
        for s in stats:
            self.stat(s)

    def stat(self, s):
        k = s[0]
        line = s[1]
        if k == "Local":
            for e in s[3]:
                self.expr(e)
            for n in s[2]:
                self.declare(n, line)
        elif k == "LocalFunc":
            self.declare(s[2], line)
            self.scope.vars[s[2]][1] = self.scope.vars[s[2]][1]
            self.funcbody(s[3])
        elif k == "FuncStat":
            target = s[2]
            if target[0] == "Name":
                if not self.is_local(target[2]):
                    self.err(line, f"function assigns global '{target[2]}'")
                else:
                    self.use(target[2], line)
            else:
                self.expr(target)
            self.funcbody(s[3])
        elif k == "Assign":
            for e in s[3]:
                self.expr(e)
            for tg in s[2]:
                self.assign_target(tg)
        elif k == "Compound":
            self.assign_target(s[3], compound=True)
            self.expr(s[4])
        elif k == "CallStat":
            self.expr(s[2])
        elif k == "Do":
            self.push()
            self.block(s[2])
            self.pop()
        elif k == "While":
            self.expr(s[2])
            self.push()
            self.block(s[3])
            self.pop()
        elif k == "Repeat":
            self.push()
            self.block(s[2])
            self.expr(s[3])
            self.pop()
        elif k == "If":
            for cond, body in s[2]:
                self.expr(cond)
                self.push()
                self.block(body)
                self.pop()
            if s[3] is not None:
                self.push()
                self.block(s[3])
                self.pop()
        elif k == "NumFor":
            self.expr(s[3])
            self.expr(s[4])
            if s[5] is not None:
                self.expr(s[5])
            self.push()
            self.declare(s[2], line)
            self.scope.vars[s[2]][1] = True
            self.block(s[6])
            self.pop()
        elif k == "GenFor":
            for e in s[3]:
                self.expr(e)
            self.push()
            for n in s[2]:
                self.declare(n, line)
            self.block(s[4])
            self.pop()
        elif k == "Return":
            for e in s[2]:
                self.expr(e)
        elif k in ("Break", "Continue"):
            pass
        else:
            self.err(line, f"linter: unhandled stat {k}")

    def assign_target(self, tg, compound=False):
        if tg[0] == "Name":
            name = tg[2]
            if not self.is_local(name):
                self.err(tg[1], f"assignment to global '{name}'")
            else:
                sc = self.scope
                while sc is not None:
                    if name in sc.vars:
                        if compound:
                            sc.vars[name][1] = True
                        break
                    sc = sc.parent
        else:
            self.expr(tg)

    def funcbody(self, fb):
        _, line, params, vararg, body, name, end_line = fb
        self.push(True)
        for p in params:
            self.declare(p, line)
            # parameters unused are fine
            self.scope.vars[p][1] = True
        self.block(body)
        self.pop()

    def expr(self, e):
        k = e[0]
        line = e[1]
        if k in ("Nil", "True", "False", "Num", "Str", "Vararg"):
            return
        if k == "Name":
            self.use(e[2], line)
            return
        if k == "Index":
            # Enum check
            obj = e[2]
            key = e[3]
            if obj[0] == "Index" and obj[2][0] == "Name" and obj[2][2] == "Enum" and not self.is_local("Enum") \
                    and obj[3][0] == "Str" and key[0] == "Str":
                enum = obj[3][2]
                item = key[2]
                if enum not in ENUMS:
                    self.err(line, f"unknown Enum type 'Enum.{enum}'" + self.suggest(enum, ENUMS.keys()))
                elif item not in ENUMS[enum] and item not in ("GetEnumItems", "FromName", "FromValue"):
                    self.err(line, f"unknown Enum item 'Enum.{enum}.{item}'" + self.suggest(item, ENUMS[enum].keys()))
            elif obj[0] == "Name" and obj[2] == "Enum" and not self.is_local("Enum") and key[0] == "Str":
                if key[2] not in ENUMS and key[2] not in ("GetEnums",):
                    self.err(line, f"unknown Enum type 'Enum.{key[2]}'" + self.suggest(key[2], ENUMS.keys()))
            self.expr(obj)
            self.expr(key)
            return
        if k == "Call":
            fn = e[2]
            args = e[3]
            # Instance.new("X")
            if fn[0] == "Index" and fn[2][0] == "Name" and fn[2][2] == "Instance" and fn[3][0] == "Str" \
                    and fn[3][2] == "new" and args and args[0][0] == "Str":
                cls = args[0][2]
                if cls not in CREATABLE:
                    self.err(line, f"Instance.new: unknown/uncreatable class '{cls}'" + self.suggest(cls, CREATABLE))
            self.expr(fn)
            for a in args:
                self.expr(a)
            return
        if k == "Method":
            obj = e[2]
            name = e[3]
            args = e[4]
            if name == "GetService" and args and args[0][0] == "Str":
                svc = args[0][2]
                if svc not in SERVICES:
                    self.err(line, f"GetService: unknown service '{svc}'" + self.suggest(svc, SERVICES))
            self.expr(obj)
            for a in args:
                self.expr(a)
            return
        if k == "Function":
            self.funcbody(e[2])
            return
        if k in ("Paren", "Cast"):
            self.expr(e[2])
            return
        if k in ("And", "Or"):
            self.expr(e[2])
            self.expr(e[3])
            return
        if k == "Un":
            self.expr(e[3])
            return
        if k == "Bin":
            self.expr(e[3])
            self.expr(e[4])
            return
        if k == "IfExpr":
            for c, v in e[2]:
                self.expr(c)
                self.expr(v)
            self.expr(e[3])
            return
        if k == "Interp":
            for x in e[3]:
                self.expr(x)
            return
        if k == "Table":
            for it in e[2]:
                if it[0] == "pos":
                    self.expr(it[1])
                elif it[0] == "named":
                    self.expr(it[2])
                else:
                    self.expr(it[1])
                    self.expr(it[2])
            return
        self.err(line, f"linter: unhandled expr {k}")

    @staticmethod
    def suggest(name, options):
        m = difflib.get_close_matches(name, list(options), n=1)
        return f" (did you mean '{m[0]}'?)" if m else ""


def lint_file(path):
    with open(path, "rb") as f:
        src = f.read().decode("latin-1")
    L = Linter(path, src)
    L.run()
    return L.errors, L.warnings


def main(paths, show_warnings=True):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, fs in os.walk(p):
                for f in sorted(fs):
                    if f.endswith(".luau") or f.endswith(".lua"):
                        files.append(os.path.join(root, f))
        else:
            files.append(p)
    nerr = 0
    nwarn = 0
    for f in sorted(files):
        errs, warns = lint_file(f)
        for e in errs:
            print(e)
        if show_warnings:
            for w in warns:
                print(w)
        nerr += len(errs)
        nwarn += len(warns)
    print(f"lint: {len(files)} files, {nerr} errors, {nwarn} warnings")
    return nerr


if __name__ == "__main__":
    args = sys.argv[1:]
    sw = "--no-warn" not in args
    args = [a for a in args if a != "--no-warn"]
    sys.exit(1 if main(args, sw) else 0)
