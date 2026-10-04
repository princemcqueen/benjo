"""Roblox class database (subset used by the game): inheritance, properties
(with types/defaults), events. Property names here must exist in Roblox."""
from rbx_types import (Vector3, Vector2, CFrame, Color3, UDim, UDim2, Rect, NumberRange,
                       NumberSequence, NumberSequenceKeypoint, ColorSequence, ColorSequenceKeypoint,
                       Font, E, font_from_enum)

INF = float("inf")


def C(r, g, b):
    return Color3(r / 255, g / 255, b / 255)


def NS(v):
    return NumberSequence([NumberSequenceKeypoint(0, v), NumberSequenceKeypoint(1, v)])


def CS(c):
    return ColorSequence([ColorSequenceKeypoint(0, c), ColorSequenceKeypoint(1, c)])


CLASSES = {}


class ClassInfo:
    def __init__(self, name, sup, props, events, creatable, service, ro):
        self.name = name
        self.sup = sup
        self.props = props
        self.events = events
        self.creatable = creatable
        self.service = service
        self.ro = ro
        self._all_props = None
        self._all_events = None
        self._ancestors = None

    def ancestors(self):
        if self._ancestors is None:
            res = [self.name]
            s = self.sup
            while s:
                res.append(s)
                s = CLASSES[s].sup
            self._ancestors = res
        return self._ancestors

    def all_props(self):
        if self._all_props is None:
            d = {}
            for cn in reversed(self.ancestors()):
                d.update(CLASSES[cn].props)
            self._all_props = d
        return self._all_props

    def all_events(self):
        if self._all_events is None:
            s = set()
            for cn in self.ancestors():
                s.update(CLASSES[cn].events)
            self._all_events = s
        return self._all_events

    def is_ro(self, prop):
        for cn in self.ancestors():
            if prop in CLASSES[cn].ro:
                return True
        return False


def cls(name, sup=None, props=None, events="", creatable=True, service=False, ro=""):
    p = {}
    ro_set = set()
    for k, v in (props or {}).items():
        t, d = v
        if t.startswith("ro:"):
            t = t[3:]
            ro_set.add(k)
        p[k] = (t, d)
    ro_set.update(x for x in ro.split() if x)
    CLASSES[name] = ClassInfo(name, sup, p, set(events.split()), creatable, service, ro_set)


# ---------------------------------------------------------------- base
cls("Instance", None, {
    "Name": ("str", None), "Archivable": ("bool", True), "ClassName": ("ro:str", None),
    "Parent": ("Inst?", None),
}, "Changed ChildAdded ChildRemoved DescendantAdded DescendantRemoving AncestryChanged Destroying AttributeChanged",
    creatable=False)

cls("Folder", "Instance")
cls("Configuration", "Instance")
cls("DataModel", "Instance", {"PlaceId": ("ro:num", 0), "GameId": ("ro:num", 0), "JobId": ("ro:str", "sim-job"),
                              "PlaceVersion": ("ro:num", 1), "CreatorId": ("ro:num", 0)},
    "Close", creatable=False)

# ---------------------------------------------------------------- values
for vn, t, d in (("StringValue", "str", ""), ("IntValue", "int", 0.0), ("NumberValue", "num", 0.0),
                 ("BoolValue", "bool", False), ("ObjectValue", "Inst?", None),
                 ("CFrameValue", "CF", CFrame()), ("Vector3Value", "V3", Vector3()),
                 ("Color3Value", "C3", Color3())):
    cls(vn, "Instance", {"Value": (t, d)})

cls("BindableEvent", "Instance", {}, "Event")
cls("BindableFunction", "Instance", {}, "")
cls("RemoteEvent", "Instance", {}, "OnServerEvent OnClientEvent")
cls("UnreliableRemoteEvent", "Instance", {}, "OnServerEvent OnClientEvent")
cls("RemoteFunction", "Instance", {}, "")

cls("LuaSourceContainer", "Instance", {}, creatable=False)
cls("BaseScript", "LuaSourceContainer", {"Disabled": ("bool", False), "Enabled": ("bool", True),
                                         "RunContext": ("any", None)}, creatable=False)
cls("Script", "BaseScript", {"Source": ("str", "")})
cls("LocalScript", "Script", {})
cls("ModuleScript", "LuaSourceContainer", {"Source": ("str", "")})

# ---------------------------------------------------------------- 3D
cls("PVInstance", "Instance", {}, creatable=False)
cls("Model", "PVInstance", {
    "PrimaryPart": ("Inst?", None), "WorldPivot": ("CF", CFrame()),
    "ModelStreamingMode": ("Enum:ModelStreamingMode", E("ModelStreamingMode", "Default")),
}, "")
cls("WorldModel", "Model", {})
cls("BasePart", "PVInstance", {
    "Anchored": ("bool", False), "AssemblyLinearVelocity": ("V3", Vector3()),
    "AssemblyAngularVelocity": ("V3", Vector3()), "CFrame": ("CF", CFrame()),
    "CanCollide": ("bool", True), "CanQuery": ("bool", True), "CanTouch": ("bool", True),
    "CastShadow": ("bool", True), "CollisionGroup": ("str", "Default"), "Color": ("C3", C(163, 162, 165)),
    "Massless": ("bool", False), "Material": ("Enum:Material", E("Material", "Plastic")),
    "Reflectance": ("num", 0.0), "RootPriority": ("int", 0.0), "Size": ("V3", Vector3(4, 1, 2)),
    "Transparency": ("num", 0.0), "LocalTransparencyModifier": ("num", 0.0), "Locked": ("bool", False),
    "Position": ("V3", None), "Orientation": ("V3", None), "Rotation": ("V3", None),
    "PivotOffset": ("CF", CFrame()), "CustomPhysicalProperties": ("PhysProps?", None),
    "TopSurface": ("Enum:SurfaceType", E("SurfaceType", "Smooth")),
    "BottomSurface": ("Enum:SurfaceType", E("SurfaceType", "Smooth")),
    "FrontSurface": ("Enum:SurfaceType", E("SurfaceType", "Smooth")),
    "BackSurface": ("Enum:SurfaceType", E("SurfaceType", "Smooth")),
    "LeftSurface": ("Enum:SurfaceType", E("SurfaceType", "Smooth")),
    "RightSurface": ("Enum:SurfaceType", E("SurfaceType", "Smooth")),
    "BrickColor": ("BrickColor", None), "AssemblyMass": ("ro:num", 1.0), "Mass": ("ro:num", 1.0),
    "AssemblyRootPart": ("ro:Inst?", None), "MaterialVariant": ("str", ""),
    "EnableFluidForces": ("bool", True), "ReceiveAge": ("ro:num", 0.0),
}, "Touched TouchEnded", creatable=False)
cls("Part", "BasePart", {"Shape": ("Enum:PartType", E("PartType", "Block"))})
cls("FormFactorPart", "BasePart", {}, creatable=False)
cls("WedgePart", "BasePart", {})
cls("CornerWedgePart", "BasePart", {})
cls("TrussPart", "BasePart", {})
cls("MeshPart", "BasePart", {"MeshId": ("str", ""), "TextureID": ("str", ""), "DoubleSided": ("bool", False),
                             "RenderFidelity": ("Enum:RenderFidelity", E("RenderFidelity", "Automatic")),
                             "CollisionFidelity": ("Enum:CollisionFidelity", E("CollisionFidelity", "Default")),
                             "MeshSize": ("ro:V3", Vector3(1, 1, 1))})
cls("Seat", "Part", {"Disabled": ("bool", False), "Occupant": ("ro:Inst?", None)})
cls("VehicleSeat", "BasePart", {"Disabled": ("bool", False), "Occupant": ("ro:Inst?", None)})
cls("SpawnLocation", "Part", {"Enabled": ("bool", True), "Duration": ("num", 10.0), "Neutral": ("bool", True),
                              "AllowTeamChangeOnTouch": ("bool", False)})
cls("Terrain", "BasePart", {
    "Decoration": ("bool", False), "GrassLength": ("num", 0.7), "WaterColor": ("C3", C(12, 84, 92)),
    "WaterReflectance": ("num", 1.0), "WaterTransparency": ("num", 0.3), "WaterWaveSize": ("num", 0.15),
    "WaterWaveSpeed": ("num", 10.0), "MaxExtents": ("ro:any", None),
}, creatable=False)

cls("Attachment", "Instance", {
    "CFrame": ("CF", CFrame()), "Position": ("V3", None), "Orientation": ("V3", None),
    "Axis": ("V3", None), "SecondaryAxis": ("V3", None), "Visible": ("bool", False),
    "WorldCFrame": ("CF", None), "WorldPosition": ("V3", None), "WorldOrientation": ("ro:V3", None),
    "WorldAxis": ("ro:V3", None), "WorldSecondaryAxis": ("ro:V3", None),
})
cls("AnimationController", "Instance", {})
cls("Bone", "Attachment", {"Transform": ("CF", CFrame()), "TransformedCFrame": ("ro:CF", None),
                           "TransformedWorldCFrame": ("ro:CF", None)})

cls("JointInstance", "Instance", {"C0": ("CF", CFrame()), "C1": ("CF", CFrame()), "Part0": ("Inst?", None),
                                  "Part1": ("Inst?", None), "Enabled": ("bool", True), "Active": ("ro:bool", True)},
    creatable=False)
cls("Weld", "JointInstance", {})
cls("Motor", "JointInstance", {"CurrentAngle": ("num", 0.0), "DesiredAngle": ("num", 0.0),
                               "MaxVelocity": ("num", 0.0)}, creatable=False)
cls("Motor6D", "Motor", {"Transform": ("CF", CFrame())})
cls("WeldConstraint", "Instance", {"Part0": ("Inst?", None), "Part1": ("Inst?", None), "Enabled": ("bool", True),
                                   "Active": ("ro:bool", True)})
cls("NoCollisionConstraint", "Instance", {"Part0": ("Inst?", None), "Part1": ("Inst?", None),
                                          "Enabled": ("bool", True)})

cls("Constraint", "Instance", {"Attachment0": ("Inst?", None), "Attachment1": ("Inst?", None),
                               "Enabled": ("bool", True), "Visible": ("bool", False), "Active": ("ro:bool", True)},
    creatable=False)
cls("LinearVelocity", "Constraint", {
    "VectorVelocity": ("V3", Vector3()), "MaxForce": ("num", 1000.0), "RelativeTo": ("Enum:ActuatorRelativeTo", E("ActuatorRelativeTo", "World")),
    "VelocityConstraintMode": ("Enum:VelocityConstraintMode", E("VelocityConstraintMode", "Vector")),
    "LineDirection": ("V3", Vector3(1, 0, 0)), "LineVelocity": ("num", 0.0), "PlaneVelocity": ("V2", Vector2()),
    "PrimaryTangentAxis": ("V3", Vector3(1, 0, 0)), "SecondaryTangentAxis": ("V3", Vector3(0, 1, 0)),
    "ForceLimitsEnabled": ("bool", True), "MaxAxesForce": ("V3", Vector3(1000, 1000, 1000)),
    "MaxPlanarAxesForce": ("V2", Vector2(1000, 1000)),
})
cls("AngularVelocity", "Constraint", {"AngularVelocity": ("V3", Vector3()), "MaxTorque": ("num", 0.0),
                                      "ReactionTorqueEnabled": ("bool", False),
                                      "RelativeTo": ("Enum:ActuatorRelativeTo", E("ActuatorRelativeTo", "World"))})
cls("AlignOrientation", "Constraint", {
    "CFrame": ("CF", CFrame()), "MaxAngularVelocity": ("num", INF), "MaxTorque": ("num", 10000.0),
    "Mode": ("Enum:OrientationAlignmentMode", E("OrientationAlignmentMode", "TwoAttachment")),
    "PrimaryAxisOnly": ("bool", False), "ReactionTorqueEnabled": ("bool", False),
    "Responsiveness": ("num", 10.0), "RigidityEnabled": ("bool", False),
    "PrimaryAxis": ("V3", Vector3(1, 0, 0)), "SecondaryAxis": ("V3", Vector3(0, 1, 0)),
    "LookAtPosition": ("V3", Vector3()),
})
cls("AlignPosition", "Constraint", {
    "Position": ("V3", Vector3()), "MaxForce": ("num", 10000.0), "MaxVelocity": ("num", INF),
    "Mode": ("Enum:PositionAlignmentMode", E("PositionAlignmentMode", "TwoAttachment")),
    "Responsiveness": ("num", 10.0), "RigidityEnabled": ("bool", False), "ApplyAtCenterOfMass": ("bool", False),
    "ReactionForceEnabled": ("bool", False),
})
cls("VectorForce", "Constraint", {"Force": ("V3", Vector3()), "ApplyAtCenterOfMass": ("bool", False),
                                  "RelativeTo": ("Enum:ActuatorRelativeTo", E("ActuatorRelativeTo", "Attachment0"))})

cls("DataModelMesh", "Instance", {"Scale": ("V3", Vector3(1, 1, 1)), "Offset": ("V3", Vector3()),
                                  "VertexColor": ("V3", Vector3(1, 1, 1))}, creatable=False)
cls("FileMesh", "DataModelMesh", {"MeshId": ("str", ""), "TextureId": ("str", "")}, creatable=False)
cls("SpecialMesh", "FileMesh", {"MeshType": ("Enum:MeshType", E("MeshType", "Head"))})
cls("BlockMesh", "DataModelMesh", {})

cls("Decal", "Instance", {"Texture": ("str", ""), "Color3": ("C3", C(255, 255, 255)), "Transparency": ("num", 0.0),
                          "Face": ("Enum:NormalId", E("NormalId", "Front")), "ZIndex": ("int", 1.0)})
cls("Texture", "Decal", {"StudsPerTileU": ("num", 2.0), "StudsPerTileV": ("num", 2.0),
                         "OffsetStudsU": ("num", 0.0), "OffsetStudsV": ("num", 0.0)})

cls("Light", "Instance", {"Brightness": ("num", 1.0), "Color": ("C3", C(255, 255, 255)),
                          "Enabled": ("bool", True), "Shadows": ("bool", False)}, creatable=False)
cls("PointLight", "Light", {"Range": ("num", 8.0)})
cls("SpotLight", "Light", {"Range": ("num", 16.0), "Angle": ("num", 90.0),
                           "Face": ("Enum:NormalId", E("NormalId", "Front"))})
cls("SurfaceLight", "Light", {"Range": ("num", 16.0), "Angle": ("num", 90.0),
                              "Face": ("Enum:NormalId", E("NormalId", "Front"))})

cls("ParticleEmitter", "Instance", {
    "Acceleration": ("V3", Vector3()), "Brightness": ("num", 1.0), "Color": ("CS", CS(C(255, 255, 255))),
    "Drag": ("num", 0.0), "EmissionDirection": ("Enum:NormalId", E("NormalId", "Top")), "Enabled": ("bool", True),
    "Lifetime": ("NR", NumberRange(5, 10)), "LightEmission": ("num", 0.0), "LightInfluence": ("num", 0.0),
    "LockedToPart": ("bool", False), "Orientation": ("Enum:ParticleOrientation", E("ParticleOrientation", "FacingCamera")),
    "Rate": ("num", 20.0), "RotSpeed": ("NR", NumberRange(0, 0)), "Rotation": ("NR", NumberRange(0, 0)),
    "Shape": ("Enum:ParticleEmitterShape", E("ParticleEmitterShape", "Box")),
    "ShapeInOut": ("Enum:ParticleEmitterShapeInOut", E("ParticleEmitterShapeInOut", "Outward")),
    "ShapePartial": ("num", 1.0), "ShapeStyle": ("Enum:ParticleEmitterShapeStyle", E("ParticleEmitterShapeStyle", "Volume")),
    "Size": ("NS", NS(1)), "Speed": ("NR", NumberRange(5, 5)), "SpreadAngle": ("V2", Vector2()),
    "Squash": ("NS", NS(0)), "Texture": ("str", "rbxasset://textures/particles/sparkles_main.dds"),
    "TimeScale": ("num", 1.0), "Transparency": ("NS", NS(0)), "VelocityInheritance": ("num", 0.0),
    "ZOffset": ("num", 0.0), "WindAffectsDrag": ("bool", False),
})
cls("Beam", "Instance", {
    "Attachment0": ("Inst?", None), "Attachment1": ("Inst?", None), "Brightness": ("num", 1.0),
    "Color": ("CS", CS(C(255, 255, 255))), "CurveSize0": ("num", 0.0), "CurveSize1": ("num", 0.0),
    "Enabled": ("bool", True), "FaceCamera": ("bool", False), "LightEmission": ("num", 0.0),
    "LightInfluence": ("num", 0.0), "Segments": ("int", 10.0), "Texture": ("str", ""),
    "TextureLength": ("num", 1.0), "TextureMode": ("Enum:TextureMode", E("TextureMode", "Stretch")),
    "TextureSpeed": ("num", 1.0), "Transparency": ("NS", NS(0.5)), "Width0": ("num", 1.0), "Width1": ("num", 1.0),
    "ZOffset": ("num", 0.0),
})
cls("Trail", "Instance", {
    "Attachment0": ("Inst?", None), "Attachment1": ("Inst?", None), "Brightness": ("num", 1.0),
    "Color": ("CS", CS(C(255, 255, 255))), "Enabled": ("bool", True), "FaceCamera": ("bool", False),
    "Lifetime": ("num", 2.0), "LightEmission": ("num", 0.0), "LightInfluence": ("num", 0.0),
    "MaxLength": ("num", 0.0), "MinLength": ("num", 0.1), "Texture": ("str", ""), "TextureLength": ("num", 1.0),
    "TextureMode": ("Enum:TextureMode", E("TextureMode", "Stretch")), "Transparency": ("NS", NS(0.5)),
    "WidthScale": ("NS", NS(1)),
})
cls("Highlight", "Instance", {
    "Adornee": ("Inst?", None), "DepthMode": ("Enum:HighlightDepthMode", E("HighlightDepthMode", "AlwaysOnTop")),
    "Enabled": ("bool", True), "FillColor": ("C3", C(255, 0, 0)), "FillTransparency": ("num", 0.5),
    "OutlineColor": ("C3", C(255, 255, 255)), "OutlineTransparency": ("num", 0.0),
})
cls("Fire", "Instance", {"Color": ("C3", C(236, 139, 70)), "SecondaryColor": ("C3", C(139, 80, 55)),
                         "Enabled": ("bool", True), "Heat": ("num", 9.0), "Size": ("num", 5.0), "TimeScale": ("num", 1.0)})
cls("Smoke", "Instance", {"Color": ("C3", C(255, 255, 255)), "Enabled": ("bool", True), "Opacity": ("num", 0.5),
                          "RiseVelocity": ("num", 1.0), "Size": ("num", 1.0), "TimeScale": ("num", 1.0)})
cls("Sparkles", "Instance", {"SparkleColor": ("C3", C(144, 25, 255)), "Enabled": ("bool", True), "TimeScale": ("num", 1.0)})

cls("Sound", "Instance", {
    "Looped": ("bool", False), "PlayOnRemove": ("bool", False), "PlaybackSpeed": ("num", 1.0),
    "Playing": ("bool", False), "RollOffMaxDistance": ("num", 10000.0), "RollOffMinDistance": ("num", 10.0),
    "RollOffMode": ("Enum:RollOffMode", E("RollOffMode", "Inverse")), "SoundGroup": ("Inst?", None),
    "SoundId": ("str", ""), "TimePosition": ("num", 0.0), "Volume": ("num", 0.5),
    "IsLoaded": ("ro:bool", True), "IsPlaying": ("ro:bool", False), "TimeLength": ("ro:num", 1.0),
    "PlaybackLoudness": ("ro:num", 0.0),
}, "Ended Loaded Played Paused Resumed Stopped DidLoop")
cls("SoundGroup", "Instance", {"Volume": ("num", 0.5)})
cls("SoundEffect", "Instance", {"Enabled": ("bool", True), "Priority": ("int", 0.0)}, creatable=False)
cls("ReverbSoundEffect", "SoundEffect", {"DecayTime": ("num", 1.5), "Density": ("num", 1.0), "Diffusion": ("num", 1.0),
                                         "DryLevel": ("num", -6.0), "WetLevel": ("num", 0.0)})
cls("EqualizerSoundEffect", "SoundEffect", {"HighGain": ("num", 0.0), "LowGain": ("num", -20.0), "MidGain": ("num", -10.0)})

cls("ProximityPrompt", "Instance", {
    "ActionText": ("str", "Interact"), "ObjectText": ("str", ""), "ClickablePrompt": ("bool", True),
    "Enabled": ("bool", True), "Exclusivity": ("Enum:ProximityPromptExclusivity", E("ProximityPromptExclusivity", "OnePerButton")),
    "GamepadKeyCode": ("Enum:KeyCode", E("KeyCode", "ButtonX")), "HoldDuration": ("num", 0.0),
    "KeyboardKeyCode": ("Enum:KeyCode", E("KeyCode", "E")), "MaxActivationDistance": ("num", 10.0),
    "RequiresLineOfSight": ("bool", True), "Style": ("Enum:ProximityPromptStyle", E("ProximityPromptStyle", "Default")),
    "UIOffset": ("V2", Vector2()), "AutoLocalize": ("bool", True),
}, "PromptButtonHoldBegan PromptButtonHoldEnded PromptHidden PromptShown TriggerEnded Triggered")
cls("ClickDetector", "Instance", {"MaxActivationDistance": ("num", 32.0), "CursorIcon": ("str", "")},
    "MouseClick MouseHoverEnter MouseHoverLeave")

cls("Camera", "Instance", {
    "CFrame": ("CF", CFrame((0, 20, 20))), "CameraSubject": ("Inst?", None),
    "CameraType": ("Enum:CameraType", E("CameraType", "Custom")), "FieldOfView": ("num", 70.0),
    "Focus": ("CF", CFrame()), "HeadLocked": ("bool", True), "ViewportSize": ("ro:V2", Vector2(1920, 1080)),
    "NearPlaneZ": ("ro:num", -0.5), "MaxAxisFieldOfView": ("num", 70.0), "DiagonalFieldOfView": ("num", 70.0),
})

cls("Humanoid", "Instance", {
    "AutoJumpEnabled": ("bool", True), "AutoRotate": ("bool", True), "BreakJointsOnDeath": ("bool", True),
    "CameraOffset": ("V3", Vector3()), "DisplayName": ("str", ""), "Health": ("num", 100.0),
    "HipHeight": ("num", 2.0), "Jump": ("bool", False), "JumpHeight": ("num", 7.2), "JumpPower": ("num", 50.0),
    "MaxHealth": ("num", 100.0), "MaxSlopeAngle": ("num", 89.0), "MoveDirection": ("ro:V3", Vector3()),
    "PlatformStand": ("bool", False), "RequiresNeck": ("bool", True), "RootPart": ("ro:Inst?", None),
    "SeatPart": ("ro:Inst?", None), "Sit": ("bool", False), "UseJumpPower": ("bool", True),
    "WalkSpeed": ("num", 16.0), "FloorMaterial": ("ro:Enum:Material", E("Material", "Air")),
    "DisplayDistanceType": ("Enum:HumanoidDisplayDistanceType", E("HumanoidDisplayDistanceType", "Viewer")),
    "RigType": ("Enum:HumanoidRigType", E("HumanoidRigType", "R15")), "WalkToPoint": ("V3", Vector3()),
    "NameDisplayDistance": ("num", 100.0), "HealthDisplayDistance": ("num", 100.0),
    "EvaluateStateMachine": ("bool", True),
}, "Died Seated StateChanged Running Jumping FreeFalling MoveToFinished HealthChanged Touched")
cls("Animator", "Instance", {}, "AnimationPlayed")
cls("Animation", "Instance", {"AnimationId": ("str", "")})

cls("Player", "Instance", {
    "UserId": ("ro:num", 0.0), "DisplayName": ("str", ""), "Character": ("Inst?", None),
    "AccountAge": ("ro:num", 100.0), "CameraMaxZoomDistance": ("num", 400.0), "CameraMinZoomDistance": ("num", 0.5),
    "ReplicationFocus": ("Inst?", None), "RespawnLocation": ("Inst?", None), "Neutral": ("bool", True),
    "DevCameraOcclusionMode": ("Enum:DevCameraOcclusionMode", E("DevCameraOcclusionMode", "Zoom")),
    "GameplayPaused": ("bool", False),
}, "CharacterAdded CharacterRemoving CharacterAppearanceLoaded Chatted Idled", creatable=False)
cls("PlayerGui", "Instance", {"SelectionImageObject": ("Inst?", None), "ScreenOrientation": ("any", None)},
    creatable=False)
cls("PlayerScripts", "Instance", {}, creatable=False)
cls("Backpack", "Instance", {}, creatable=False)
cls("StarterGear", "Instance", {}, creatable=False)

# ---------------------------------------------------------------- environment
cls("Atmosphere", "Instance", {"Color": ("C3", C(199, 199, 199)), "Decay": ("C3", C(106, 112, 125)),
                               "Density": ("num", 0.395), "Glare": ("num", 0.0), "Haze": ("num", 0.0),
                               "Offset": ("num", 0.0)})
cls("Sky", "Instance", {"CelestialBodiesShown": ("bool", True), "MoonAngularSize": ("num", 11.0),
                        "MoonTextureId": ("str", ""), "SkyboxBk": ("str", ""), "SkyboxDn": ("str", ""),
                        "SkyboxFt": ("str", ""), "SkyboxLf": ("str", ""), "SkyboxRt": ("str", ""),
                        "SkyboxUp": ("str", ""), "StarCount": ("num", 3000.0), "SunAngularSize": ("num", 21.0),
                        "SunTextureId": ("str", "")})
cls("Clouds", "Instance", {"Color": ("C3", C(255, 255, 255)), "Cover": ("num", 0.5), "Density": ("num", 0.7),
                           "Enabled": ("bool", True)})
cls("PostEffect", "Instance", {"Enabled": ("bool", True)}, creatable=False)
cls("BloomEffect", "PostEffect", {"Intensity": ("num", 1.0), "Size": ("num", 24.0), "Threshold": ("num", 2.0)})
cls("BlurEffect", "PostEffect", {"Size": ("num", 24.0)})
cls("ColorCorrectionEffect", "PostEffect", {"Brightness": ("num", 0.0), "Contrast": ("num", 0.0),
                                            "Saturation": ("num", 0.0), "TintColor": ("C3", C(255, 255, 255))})
cls("SunRaysEffect", "PostEffect", {"Intensity": ("num", 0.25), "Spread": ("num", 1.0)})
cls("DepthOfFieldEffect", "PostEffect", {"FarIntensity": ("num", 0.75), "FocusDistance": ("num", 0.05),
                                         "InFocusRadius": ("num", 10.0), "NearIntensity": ("num", 0.75)})
cls("Explosion", "Instance", {"BlastPressure": ("num", 500000.0), "BlastRadius": ("num", 4.0),
                              "Position": ("V3", Vector3()), "Visible": ("bool", True),
                              "DestroyJointRadiusPercent": ("num", 1.0)}, "Hit")

# ---------------------------------------------------------------- GUI
cls("GuiBase", "Instance", {}, creatable=False)
cls("GuiBase2d", "GuiBase", {
    "AbsolutePosition": ("ro:V2", None), "AbsoluteSize": ("ro:V2", None), "AbsoluteRotation": ("ro:num", 0.0),
    "AutoLocalize": ("bool", True), "SelectionGroup": ("bool", False),
}, creatable=False)
cls("GuiObject", "GuiBase2d", {
    "Active": ("bool", False), "AnchorPoint": ("V2", Vector2()), "AutomaticSize": ("Enum:AutomaticSize", E("AutomaticSize", "None")),
    "BackgroundColor3": ("C3", C(255, 255, 255)), "BackgroundTransparency": ("num", 0.0),
    "BorderColor3": ("C3", C(27, 42, 53)), "BorderSizePixel": ("int", 1.0), "ClipsDescendants": ("bool", False),
    "Interactable": ("bool", True), "LayoutOrder": ("int", 0.0), "Position": ("UDim2", UDim2()),
    "Rotation": ("num", 0.0), "Selectable": ("bool", False), "SelectionOrder": ("int", 0.0),
    "Size": ("UDim2", UDim2(0, 100, 0, 100)), "SizeConstraint": ("Enum:SizeConstraint", E("SizeConstraint", "RelativeXY")),
    "Visible": ("bool", True), "ZIndex": ("int", 1.0), "NextSelectionDown": ("Inst?", None),
    "NextSelectionUp": ("Inst?", None), "NextSelectionLeft": ("Inst?", None), "NextSelectionRight": ("Inst?", None),
    "SelectionImageObject": ("Inst?", None), "GuiState": ("ro:any", None),
}, "InputBegan InputChanged InputEnded MouseEnter MouseLeave MouseMoved MouseWheelForward MouseWheelBackward "
   "SelectionGained SelectionLost TouchTap TouchPan TouchPinch TouchLongPress TouchRotate TouchSwipe",
    creatable=False)
cls("Frame", "GuiObject", {})
cls("GuiButton", "GuiObject", {"AutoButtonColor": ("bool", True), "Modal": ("bool", False),
                               "Selected": ("bool", False)},
    "Activated MouseButton1Click MouseButton1Down MouseButton1Up MouseButton2Click MouseButton2Down MouseButton2Up",
    creatable=False)

TEXT_PROPS = {
    "Text": ("str", "Label"), "Font": ("Enum:Font", E("Font", "SourceSans")), "FontFace": ("Font", None),
    "LineHeight": ("num", 1.0), "MaxVisibleGraphemes": ("int", -1.0), "RichText": ("bool", False),
    "TextColor3": ("C3", C(27, 42, 53)), "TextScaled": ("bool", False), "TextSize": ("num", 14.0),
    "TextStrokeColor3": ("C3", C(0, 0, 0)), "TextStrokeTransparency": ("num", 1.0),
    "TextTransparency": ("num", 0.0), "TextTruncate": ("Enum:TextTruncate", E("TextTruncate", "None")),
    "TextWrapped": ("bool", False), "TextXAlignment": ("Enum:TextXAlignment", E("TextXAlignment", "Center")),
    "TextYAlignment": ("Enum:TextYAlignment", E("TextYAlignment", "Center")),
    "TextBounds": ("ro:V2", None), "TextFits": ("ro:bool", True), "ContentText": ("ro:str", None),
    "LocalizedText": ("ro:str", None),
}
cls("TextLabel", "GuiObject", dict(TEXT_PROPS))
cls("TextButton", "GuiButton", dict(TEXT_PROPS, Text=("str", "Button")))
cls("TextBox", "GuiObject", dict(TEXT_PROPS, Text=("str", ""), ClearTextOnFocus=("bool", True),
                                 MultiLine=("bool", False), PlaceholderText=("str", ""),
                                 PlaceholderColor3=("C3", C(178, 178, 178)), TextEditable=("bool", True),
                                 CursorPosition=("int", 1.0), SelectionStart=("int", -1.0),
                                 ShowNativeInput=("bool", True)),
    "FocusLost Focused ReturnPressedFromOnScreenKeyboard")
IMAGE_PROPS = {
    "Image": ("str", ""), "ImageColor3": ("C3", C(255, 255, 255)), "ImageRectOffset": ("V2", Vector2()),
    "ImageRectSize": ("V2", Vector2()), "ImageTransparency": ("num", 0.0),
    "ScaleType": ("Enum:ScaleType", E("ScaleType", "Stretch")), "SliceCenter": ("Rect", Rect()),
    "SliceScale": ("num", 1.0), "TileSize": ("UDim2", UDim2(1, 0, 1, 0)),
    "ResampleMode": ("Enum:ResamplerMode", E("ResamplerMode", "Default")), "IsLoaded": ("ro:bool", True),
}
cls("ImageLabel", "GuiObject", dict(IMAGE_PROPS))
cls("ImageButton", "GuiButton", dict(IMAGE_PROPS, HoverImage=("str", ""), PressedImage=("str", "")))
cls("ScrollingFrame", "GuiObject", {
    "AbsoluteCanvasSize": ("ro:V2", None), "AbsoluteWindowSize": ("ro:V2", None),
    "AutomaticCanvasSize": ("Enum:AutomaticSize", E("AutomaticSize", "None")), "BottomImage": ("str", ""),
    "MidImage": ("str", ""), "TopImage": ("str", ""), "CanvasPosition": ("V2", Vector2()),
    "CanvasSize": ("UDim2", UDim2(0, 0, 2, 0)), "ElasticBehavior": ("Enum:ElasticBehavior", E("ElasticBehavior", "WhenScrollable")),
    "HorizontalScrollBarInset": ("Enum:ScrollBarInset", E("ScrollBarInset", "None")),
    "VerticalScrollBarInset": ("Enum:ScrollBarInset", E("ScrollBarInset", "None")),
    "ScrollBarImageColor3": ("C3", C(0, 0, 0)), "ScrollBarImageTransparency": ("num", 0.0),
    "ScrollBarThickness": ("int", 12.0), "ScrollingDirection": ("Enum:ScrollingDirection", E("ScrollingDirection", "XY")),
    "ScrollingEnabled": ("bool", True), "VerticalScrollBarPosition": ("Enum:VerticalScrollBarPosition", E("VerticalScrollBarPosition", "Right")),
})
cls("ViewportFrame", "GuiObject", {
    "Ambient": ("C3", C(200, 200, 200)), "CurrentCamera": ("Inst?", None), "ImageColor3": ("C3", C(255, 255, 255)),
    "ImageTransparency": ("num", 0.0), "LightColor": ("C3", C(140, 140, 140)), "LightDirection": ("V3", Vector3(-1, -1, -1)),
})
cls("CanvasGroup", "GuiObject", {"GroupColor3": ("C3", C(255, 255, 255)), "GroupTransparency": ("num", 0.0)})
cls("VideoFrame", "GuiObject", {"Video": ("str", ""), "Looped": ("bool", False), "Playing": ("bool", False),
                                "Volume": ("num", 1.0)})

cls("LayerCollector", "GuiBase2d", {"Enabled": ("bool", True), "ResetOnSpawn": ("bool", True),
                                    "ZIndexBehavior": ("Enum:ZIndexBehavior", E("ZIndexBehavior", "Sibling"))},
    creatable=False)
cls("ScreenGui", "LayerCollector", {"DisplayOrder": ("int", 0.0), "IgnoreGuiInset": ("bool", False),
                                    "ScreenInsets": ("Enum:ScreenInsets", E("ScreenInsets", "CoreUISafeInsets")),
                                    "ClipToDeviceSafeArea": ("bool", True)})
cls("BillboardGui", "LayerCollector", {
    "Active": ("bool", False), "Adornee": ("Inst?", None), "AlwaysOnTop": ("bool", False), "Brightness": ("num", 1.0),
    "ClipsDescendants": ("bool", False), "LightInfluence": ("num", 0.0), "MaxDistance": ("num", INF),
    "Size": ("UDim2", UDim2()), "SizeOffset": ("V2", Vector2()), "StudsOffset": ("V3", Vector3()),
    "StudsOffsetWorldSpace": ("V3", Vector3()), "ExtentsOffset": ("V3", Vector3()),
    "ExtentsOffsetWorldSpace": ("V3", Vector3()), "DistanceLowerLimit": ("num", 0.0),
    "DistanceUpperLimit": ("num", -1.0), "DistanceStep": ("num", 0.0), "PlayerToHideFrom": ("Inst?", None),
    "CurrentDistance": ("ro:num", 0.0),
})
cls("SurfaceGui", "LayerCollector", {
    "Active": ("bool", True), "Adornee": ("Inst?", None), "AlwaysOnTop": ("bool", False), "Brightness": ("num", 1.0),
    "CanvasSize": ("V2", Vector2(800, 600)), "Face": ("Enum:NormalId", E("NormalId", "Front")),
    "LightInfluence": ("num", 1.0), "PixelsPerStud": ("num", 50.0),
    "SizingMode": ("Enum:SurfaceGuiSizingMode", E("SurfaceGuiSizingMode", "FixedSize")), "ZOffset": ("num", 0.0),
    "MaxDistance": ("num", 1000.0), "ClipsDescendants": ("bool", True),
})

cls("UIBase", "Instance", {}, creatable=False)
cls("UIComponent", "UIBase", {}, creatable=False)
cls("UICorner", "UIComponent", {"CornerRadius": ("UDim", UDim(0, 8))})
cls("UIStroke", "UIComponent", {
    "ApplyStrokeMode": ("Enum:ApplyStrokeMode", E("ApplyStrokeMode", "Contextual")), "Color": ("C3", C(0, 0, 0)),
    "Enabled": ("bool", True), "LineJoinMode": ("Enum:LineJoinMode", E("LineJoinMode", "Round")),
    "Thickness": ("num", 1.0), "Transparency": ("num", 0.0),
})
cls("UIGradient", "UIComponent", {"Color": ("CS", CS(C(255, 255, 255))), "Enabled": ("bool", True),
                                  "Offset": ("V2", Vector2()), "Rotation": ("num", 0.0),
                                  "Transparency": ("NS", NS(0))})
cls("UIPadding", "UIComponent", {"PaddingBottom": ("UDim", UDim()), "PaddingLeft": ("UDim", UDim()),
                                 "PaddingRight": ("UDim", UDim()), "PaddingTop": ("UDim", UDim())})
cls("UIScale", "UIComponent", {"Scale": ("num", 1.0)})
cls("UIConstraint", "UIComponent", {}, creatable=False)
cls("UIAspectRatioConstraint", "UIConstraint", {"AspectRatio": ("num", 1.0),
                                                "AspectType": ("Enum:AspectType", E("AspectType", "FitWithinMaxSize")),
                                                "DominantAxis": ("Enum:DominantAxis", E("DominantAxis", "Width"))})
cls("UISizeConstraint", "UIConstraint", {"MaxSize": ("V2", Vector2(INF, INF)), "MinSize": ("V2", Vector2(0, 0))})
cls("UITextSizeConstraint", "UIConstraint", {"MaxTextSize": ("int", 100.0), "MinTextSize": ("int", 1.0)})
cls("UILayout", "UIComponent", {}, creatable=False)
cls("UIGridStyleLayout", "UILayout", {
    "AbsoluteContentSize": ("ro:V2", None), "FillDirection": ("Enum:FillDirection", E("FillDirection", "Horizontal")),
    "HorizontalAlignment": ("Enum:HorizontalAlignment", E("HorizontalAlignment", "Left")),
    "SortOrder": ("Enum:SortOrder", E("SortOrder", "LayoutOrder")),
    "VerticalAlignment": ("Enum:VerticalAlignment", E("VerticalAlignment", "Top")),
}, creatable=False)
cls("UIListLayout", "UIGridStyleLayout", {"Padding": ("UDim", UDim()), "Wraps": ("bool", False),
                                          "FillDirection": ("Enum:FillDirection", E("FillDirection", "Vertical"))})
cls("UIGridLayout", "UIGridStyleLayout", {"CellPadding": ("UDim2", UDim2(0, 5, 0, 5)),
                                          "CellSize": ("UDim2", UDim2(0, 100, 0, 100)),
                                          "FillDirectionMaxCells": ("int", 0.0),
                                          "StartCorner": ("Enum:StartCorner", E("StartCorner", "TopLeft")),
                                          "AbsoluteCellCount": ("ro:V2", None), "AbsoluteCellSize": ("ro:V2", None)})
cls("UIPageLayout", "UIGridStyleLayout", {"Padding": ("UDim", UDim()), "Circular": ("bool", False),
                                          "CurrentPage": ("ro:Inst?", None)})

# ---------------------------------------------------------------- services
SERVICE_CLASSES = [
    "Workspace", "Players", "ReplicatedStorage", "ReplicatedFirst", "ServerStorage", "ServerScriptService",
    "StarterGui", "StarterPack", "StarterPlayer", "Lighting", "SoundService", "RunService", "UserInputService",
    "ContextActionService", "TweenService", "HttpService", "DataStoreService", "CollectionService",
    "PhysicsService", "ProximityPromptService", "GuiService", "TextService", "ContentProvider", "Debris",
    "MarketplaceService", "TeleportService", "MessagingService", "BadgeService", "Teams", "Chat",
    "TextChatService", "LogService", "Stats", "AssetService", "MaterialService", "SocialService",
    "PolicyService", "LocalizationService", "AnalyticsService", "MemoryStoreService", "HapticService",
    "VRService", "GamepadService", "StarterPlayerScripts", "TestService",
]
cls("ServiceProvider", "Instance", {}, creatable=False)
for sn in SERVICE_CLASSES:
    cls(sn, "Instance", {}, creatable=False, service=True)

CLASSES["Workspace"].sup = "Model"
CLASSES["Workspace"].props.update({
    "Gravity": ("num", 196.2), "StreamingEnabled": ("bool", False), "CurrentCamera": ("Inst?", None),
    "DistributedGameTime": ("ro:num", 0.0), "FallenPartsDestroyHeight": ("num", -500.0),
    "StreamingMinRadius": ("int", 64.0), "StreamingTargetRadius": ("int", 1024.0),
    "Terrain": ("ro:Inst?", None),
    "StreamOutBehavior": ("Enum:StreamOutBehavior", E("StreamOutBehavior", "Default")),
    "StreamingIntegrityMode": ("Enum:StreamingIntegrityMode", E("StreamingIntegrityMode", "Default")),
    "SignalBehavior": ("Enum:SignalBehavior", E("SignalBehavior", "Default")),
})
CLASSES["Players"].props.update({
    "LocalPlayer": ("ro:Inst?", None), "MaxPlayers": ("ro:num", 12.0), "RespawnTime": ("num", 5.0),
    "CharacterAutoLoads": ("bool", True), "BubbleChat": ("ro:bool", True), "ClassicChat": ("ro:bool", False),
})
CLASSES["Players"].events = {"PlayerAdded", "PlayerRemoving", "PlayerMembershipChanged"}
CLASSES["Lighting"].props.update({
    "Ambient": ("C3", C(70, 70, 70)), "Brightness": ("num", 2.0), "ColorShift_Bottom": ("C3", C(0, 0, 0)),
    "ColorShift_Top": ("C3", C(0, 0, 0)), "EnvironmentDiffuseScale": ("num", 0.0),
    "EnvironmentSpecularScale": ("num", 0.0), "ExposureCompensation": ("num", 0.0),
    "FogColor": ("C3", C(192, 192, 192)), "FogEnd": ("num", 100000.0), "FogStart": ("num", 0.0),
    "GeographicLatitude": ("num", 41.73), "GlobalShadows": ("bool", True), "OutdoorAmbient": ("C3", C(128, 128, 128)),
    "ShadowSoftness": ("num", 0.2), "ClockTime": ("num", 14.0), "TimeOfDay": ("str", "14:00:00"),
    "Technology": ("Enum:Technology", E("Technology", "ShadowMap")),
}, )
CLASSES["Lighting"].events = {"LightingChanged"}
CLASSES["RunService"].events = {"Heartbeat", "RenderStepped", "Stepped", "PreRender", "PreAnimation",
                                "PreSimulation", "PostSimulation"}
CLASSES["UserInputService"].props.update({
    "TouchEnabled": ("ro:bool", False), "KeyboardEnabled": ("ro:bool", True), "MouseEnabled": ("ro:bool", True),
    "GamepadEnabled": ("ro:bool", False), "VREnabled": ("ro:bool", False), "AccelerometerEnabled": ("ro:bool", False),
    "GyroscopeEnabled": ("ro:bool", False),
    "MouseBehavior": ("Enum:MouseBehavior", E("MouseBehavior", "Default")), "MouseIconEnabled": ("bool", True),
    "MouseDeltaSensitivity": ("num", 1.0), "OnScreenKeyboardVisible": ("ro:bool", False),
    "ModalEnabled": ("bool", False), "MouseIcon": ("str", ""),
})
CLASSES["UserInputService"].events = {"InputBegan", "InputEnded", "InputChanged", "LastInputTypeChanged",
                                      "TouchStarted", "TouchEnded", "TouchMoved", "TouchTap", "TouchPinch",
                                      "TouchPan", "TouchSwipe", "TouchLongPress", "WindowFocused",
                                      "WindowFocusReleased", "GamepadConnected", "GamepadDisconnected",
                                      "TextBoxFocused", "TextBoxFocusReleased", "JumpRequest"}
CLASSES["GuiService"].props.update({
    "TopbarInset": ("ro:Rect", Rect(0, 0, 340, 58)), "SelectedObject": ("Inst?", None),
    "AutoSelectGuiEnabled": ("bool", True), "GuiNavigationEnabled": ("bool", True),
    "MenuIsOpen": ("ro:bool", False), "CoreGuiNavigationEnabled": ("bool", True),
    "TouchControlsEnabled": ("bool", True),
})
CLASSES["GuiService"].events = {"MenuOpened", "MenuClosed"}
CLASSES["HttpService"].props.update({"HttpEnabled": ("ro:bool", False)})
CLASSES["ProximityPromptService"].props.update({"Enabled": ("bool", True), "MaxPromptsVisible": ("int", 16.0)})
CLASSES["MarketplaceService"].props.update({"ProcessReceipt": ("any", None)})
CLASSES["MarketplaceService"].events = set(CLASSES["MarketplaceService"].events or set()) | {
    "PromptGamePassPurchaseFinished", "PromptProductPurchaseFinished", "PromptPurchaseFinished"}
CLASSES["ProximityPromptService"].events = {"PromptShown", "PromptHidden", "PromptTriggered", "PromptTriggerEnded",
                                            "PromptButtonHoldBegan", "PromptButtonHoldEnded"}
CLASSES["SoundService"].props.update({"AmbientReverb": ("Enum:ReverbType", E("ReverbType", "NoReverb")),
                                      "RespectFilteringEnabled": ("bool", True), "RolloffScale": ("num", 1.0),
                                      "DistanceFactor": ("num", 3.33), "DopplerScale": ("num", 1.0)})
CLASSES["StarterGui"].props.update({"ShowDevelopmentGui": ("bool", True), "ResetPlayerGuiOnSpawn": ("bool", True),
                                    "ScreenOrientation": ("any", None)})
CLASSES["StarterPlayer"].props.update({
    "CameraMaxZoomDistance": ("num", 400.0), "CameraMinZoomDistance": ("num", 0.5),
    "CharacterWalkSpeed": ("num", 16.0), "CharacterJumpPower": ("num", 50.0), "CharacterJumpHeight": ("num", 7.2),
    "EnableMouseLockOption": ("bool", True), "AutoJumpEnabled": ("bool", True),
    "DevComputerMovementMode": ("Enum:DevComputerMovementMode", E("DevComputerMovementMode", "UserChoice")),
    "DevTouchMovementMode": ("Enum:DevTouchMovementMode", E("DevTouchMovementMode", "UserChoice")),
    "LoadCharacterAppearance": ("bool", True), "CharacterUseJumpPower": ("bool", False),
})
CLASSES["ReplicatedFirst"].events = {"FinishedReplicating", "RemoveDefaultLoadingGuiSignal"}
CLASSES["LogService"].events = {"MessageOut"}
CLASSES["DataModel"].sup = "ServiceProvider"


def is_a(class_name, other):
    ci = CLASSES.get(class_name)
    if ci is None:
        return False
    return other in ci.ancestors()
