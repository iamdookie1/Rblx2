local v1 = game:GetService("Players")
local v2 = game:GetService("RunService")
local v3 = game:GetService("ReplicatedStorage")
local v4 = game:GetService("UserInputService")
local v5 = game:GetService("CollectionService")
local v6 = game:GetService("Stats")
local v7 = workspace
local v8 = v1.LocalPlayer

local v9 = (typeof(getgenv) == "function" and getgenv()) or _G
if v9.__CustomMM2Unload then
    pcall(v9.__CustomMM2Unload)
end

local v10 = false
local v11 = {}
local function v12(v13)
    table.insert(v11, v13)
    return v13
end

local v14 = loadstring(game:HttpGet("https://github.com/SSHRKs/LumeUI/releases/latest/download/main.lua"))()

local v15 = {
    GunAim = false,
    KnifeAim = false,
    Esp = false,
    AntiFling = false,
}

local v16 = v3:WaitForChild("Remotes", 10)
local v17 = v16 and v16:WaitForChild("Gameplay", 10)
local v18 = v17 and v17:FindFirstChild("GetCurrentPlayerData")
local v19 = v17 and v17:FindFirstChild("PlayerDataChanged")

local v20 = {}
local function v21()
    if not v18 then
        return
    end
    local v22, v23 = pcall(v18.InvokeServer, v18)
    if v22 and type(v23) == "table" then
        v20 = v23
    end
end
task.spawn(v21)
if v19 then
    v12(v19.OnClientEvent:Connect(function(v24)
        if type(v24) == "table" then
            v20 = v24
        end
    end))
end
task.spawn(function()
    while not v10 do
        task.wait(3)
        v21()
    end
end)

local function v25(v26)
    if not v26:IsA("Tool") then
        return false
    end
    local v27 = false
    pcall(function()
        v27 = v5:HasTag(v26, "Weapon_Gun")
    end)
    return v26.Name == "Gun" or v27 or v26:FindFirstChild("IsGun") ~= nil
end

local function v28(v29)
    return v29:IsA("Tool") and (v29.Name == "Knife" or v29:FindFirstChild("KnifeClient") ~= nil)
end

local function v30(v31)
    local v32
    for _, v33 in { v31.Character, v31:FindFirstChildOfClass("Backpack") } do
        if v33 then
            for _, v34 in v33:GetChildren() do
                if v28(v34) then
                    return "Knife"
                elseif v25(v34) then
                    v32 = "Gun"
                end
            end
        end
    end
    return v32
end

local function v35(v36)
    local v37 = v20[v36.Name]
    local v38 = type(v37) == "table" and v37.Role or nil
    local v39 = type(v37) == "table" and (v37.Dead == true or v37.Killed == true)
    local v40 = v30(v36)
    if v40 == "Knife" then
        v38 = "Murderer"
    elseif v40 == "Gun" and v38 ~= "Sheriff" then
        v38 = v38 == "Murderer" and v38 or "Hero"
    end
    return v38, v39
end

local function v41(v42)
    local v43 = v42.Character
    local v44 = v43 and v43:FindFirstChildOfClass("Humanoid")
    local v45 = v43 and v43:FindFirstChild("HumanoidRootPart")
    if v44 and v45 and v44.Health > 0 then
        return v45, v44, v43
    end
    return nil
end

local function v46(v47)
    local v48 = { v8.Character }
    if v47 then
        table.insert(v48, v47)
    end
    for _, v49 in v5:GetTagged("WeaponPassthrough") do
        table.insert(v48, v49)
    end
    return v48
end

local function v50(v51, v52, v53)
    local v54 = RaycastParams.new()
    v54.FilterType = Enum.RaycastFilterType.Exclude
    local v55 = v46(v53)
    v54.FilterDescendantsInstances = v55
    local v56 = v52 - v51
    for _ = 1, 8 do
        local v57 = v7:Raycast(v51, v56, v54)
        if not v57 then
            return true
        end
        if v57.Instance.Transparency < 1 then
            return false
        end
        table.insert(v55, v57.Instance)
        v54.FilterDescendantsInstances = v55
    end
    return false
end

local v58, v59 = nil, 0
v12(v4.TouchTapInWorld:Connect(function(v60, v61)
    if not v61 then
        v58, v59 = v60, os.clock()
    end
end))

local function v62()
    local v63 = v8:FindFirstChild("PlayerScripts")
    local v64 = v63 and v63:FindFirstChild("MouseLock")
    return v64 and v64:GetAttribute("Enabled") == true
end

local function v65()
    local v66 = v7.CurrentCamera
    local v67 = v66.ViewportSize
    if v4.TouchEnabled and v58 and os.clock() - v59 < 0.35 then
        return Vector2.new(v58.X, v58.Y)
    end
    if v62() or v4.MouseBehavior == Enum.MouseBehavior.LockCenter then
        return v67 / 2
    end
    if v4.TouchEnabled and not v4.MouseEnabled then
        return v67 / 2
    end
    return v4:GetMouseLocation()
end

local v68 = {
    WINDOW = 3.0,
    SPAN = 0.034,
    FIT = 0.067,
    GRAVITY = 196.2,
    INTERP = 0.06,
    PROCESS = 0.01,
    FUTURES = 64,
    STEP = 1 / 30,
    MOVE_MIN = 2.0,
    MOVE_FRACTION = 0.4,
    TURN = 0.7,
    PASS = 0.12,
    PRIOR_MOVE = 1.5,
    PRIOR_STOP = 0.8,
    PRIOR_WEIGHT = 1.5,
    STOP_PRIOR = 0.5,
    TURN_PRIOR = 0.7,
    TRUST_AT = 3,
    TRUST = 0.9,
    JITTER = 0.2,
    ACCEL_LEAD = 0.05,
    ACCEL_MIN = 40,
    TURN_LAG = 0.035,
    ACCEL_TAU = 0.05,
    GUN_RADIUS = 1.0,
    KNIFE_RADIUS = 1.2,
    GUN_HOLD = 0.2,
    GUN_SURE = 0.85,
    KNIFE_HOLD = 0,
    KNIFE_SURE = 0.7,
    GUN_RAISE = 1.0,
    KNIFE_RAISE = 1.5,
    OFFSET_MIN = -0.3,
    OFFSET_MAX = 0.4,
    OFFSET_STEP = 0.005,
    OFFSET_PRIOR = 0.07,
    OFFSET_SPREAD = 0.12,
    LEARN_AFTER = 2,
}

function v68.new()
    return { list = {}, groundY = nil, grounded = true }
end

function v68.push(v69, v70, v71, v72)
    local v73 = v69.list
    local v74 = #v73
    if v74 > 0 and v70 <= v73[v74].t then
        return
    end
    v73[v74 + 1] = { t = v70, p = v71 }
    v74 += 1
    if v72 then
        v69.groundY = v71.Y
    end
    v69.grounded = v72
    local v75 = v70 - v68.WINDOW - 0.2
    local v76 = 0
    while v76 < v74 - 2 and v73[v76 + 1].t < v75 do
        v76 += 1
    end
    if v76 > 0 then
        table.move(v73, v76 + 1, v74, 1)
        for v77 = v74 - v76 + 1, v74 do
            v73[v77] = nil
        end
    end
end

function v68.at(v78, v79)
    local v80 = v78.list
    local v81 = #v80
    if v79 >= v80[v81].t then
        return v80[v81].p
    end
    if v79 <= v80[1].t then
        return v80[1].p
    end
    local v82, v83 = 1, v81
    while v83 - v82 > 1 do
        local v84 = (v82 + v83) // 2
        if v80[v84].t <= v79 then
            v82 = v84
        else
            v83 = v84
        end
    end
    local v85, v86 = v80[v82], v80[v83]
    return v85.p + (v86.p - v85.p) * ((v79 - v85.t) / math.max(v86.t - v85.t, 1e-6))
end

function v68.velocity(v87, v88, v89)
    return (v68.at(v87, v88) - v68.at(v87, v88 - v89)) / v89
end

local function v90(v91)
    v91 = (v91 + math.pi) % (2 * math.pi)
    return v91 - math.pi
end

function v68.fit(v92, v93, v94)
    local v95, v96, v97, v98, v99, v100, v101 = 0, 0, 0, 0, 0, 0, 0
    for v102 = 0, 4 do
        local v103 = -v94 * v102 / 4
        local v104 = v68.at(v92, v93 + v103)
        v95 += 1
        v96 += v103
        v97 += v104.X
        v98 += v104.Z
        v99 += v103 * v103
        v100 += v103 * v104.X
        v101 += v103 * v104.Z
    end
    local v105 = v95 * v99 - v96 * v96
    if v105 <= 1e-9 then
        return 0, 0
    end
    return (v95 * v100 - v96 * v97) / v105, (v95 * v101 - v96 * v98) / v105
end

function v68.motion(v106)
    local v107 = v106.list
    local v108 = v107[#v107].t
    local v109 = math.max(v107[1].t + v68.SPAN, v108 - v68.WINDOW)
    local v110 = {}
    local v111 = v109
    while v111 <= v108 + 1e-6 do
        local v112 = v68.velocity(v106, v111, v68.SPAN)
        v110[#v110 + 1] = { t = v111, x = v112.X, z = v112.Z, s = math.sqrt(v112.X * v112.X + v112.Z * v112.Z) }
        v111 += 1 / 60
    end
    local v113 = {}
    for _, v114 in v110 do
        if v114.s > v68.MOVE_MIN then
            v113[#v113 + 1] = v114.s
        end
    end
    table.sort(v113)
    local v115 = #v113 >= 6 and v113[math.max(1, math.floor(#v113 * 0.7))] or 16
    local v116 = math.max(v68.MOVE_MIN, v115 * v68.MOVE_FRACTION)
    local v117 = v68.ACCEL_TAU
    local v118 = v117 * math.log(1 / v68.MOVE_FRACTION) + v68.SPAN / 2
    local v119 = v117 * math.log(1 / (1 - v68.MOVE_FRACTION)) + v68.SPAN / 2
    local v120 = {
        moveDur = {}, stopDur = {}, turnAngles = {}, startAngles = {},
        stops = 0, sharp = 0, events = 0,
        typical = v115, thr = v116,
    }
    local v121, v122, v123, v124, v125, v126
    local v127, v128, v129
    local v130 = {}
    for _, v131 in v110 do
        local v132 = v131.s > v116
        local v133 = v132 and math.atan2(v131.z, v131.x) or nil
        if not v121 then
            v121 = v132 and "move" or "stop"
            v122, v123 = v131.t, false
            if v132 then
                v124 = v133
                v125, v126 = math.cos(v133), math.sin(v133)
            end
        elseif v121 == "move" then
            if v132 then
                table.insert(v130, v131)
                local v134 = v90(v133 - v124)
                if math.abs(v134) > v68.TURN then
                    local v135 = math.abs(v134) / 2
                    local v136 = v131.t
                    for _, v137 in v130 do
                        local v138 = v137.x * v125 + v137.z * v126
                        local v139 = math.abs(v137.x * v126 - v137.z * v125)
                        if math.atan2(v139, v138) >= v135 then
                            v136 = v137.t
                            break
                        end
                    end
                    v136 -= v68.TURN_LAG + v68.SPAN / 2
                    if v123 then
                        table.insert(v120.moveDur, v136 - v122)
                    end
                    table.insert(v120.turnAngles, v134)
                    v120.events += 1
                    if math.abs(v134) > 1.6 then
                        v120.sharp += 1
                    end
                    v122, v123 = v136, true
                    v124 = v133
                    v125, v126 = math.cos(v133), math.sin(v133)
                    v130 = {}
                end
            else
                v121 = "low"
                v127 = v131.t
                v128 = v131.t - v118
                v129 = v124
            end
        elseif v121 == "low" then
            if v132 then
                local v140 = v90(v133 - v129)
                if v131.t - v127 < v68.PASS then
                    if math.abs(v140) > v68.TURN then
                        local v141 = (v128 + v131.t - v119) / 2
                        if v123 then
                            table.insert(v120.moveDur, v141 - v122)
                        end
                        table.insert(v120.turnAngles, v140)
                        v120.events += 1
                        if math.abs(v140) > 1.6 then
                            v120.sharp += 1
                        end
                        v122, v123 = v141, true
                    end
                else
                    local v142 = v131.t - v119
                    if v123 then
                        table.insert(v120.moveDur, v128 - v122)
                    end
                    table.insert(v120.stopDur, v142 - v128)
                    table.insert(v120.startAngles, v140)
                    v120.stops += 1
                    v120.events += 1
                    v122, v123 = v142, true
                end
                v121 = "move"
                v124 = v133
                v125, v126 = math.cos(v133), math.sin(v133)
                v130 = {}
            end
        else
            if v132 then
                v121 = "move"
                v122, v123 = v131.t - v119, false
                v124 = v133
                v125, v126 = math.cos(v133), math.sin(v133)
                v130 = {}
            end
        end
    end
    v120.state = v121
    v120.ref = v124
    if v121 == "move" then
        v120.elapsed = v108 - v122
    elseif v121 == "low" then
        v120.lowFor = v108 - v127
        v120.elapsed = v108 - v128
        v120.ref = v129
        if v120.lowFor >= v68.PASS then
            v120.state = "stop"
        end
    else
        v120.elapsed = v108 - v109
    end
    return v120
end

local function v143(v144)
    if v144 >= v68.TRUST_AT then
        return v68.TRUST
    end
    return v144 / (v144 + v68.PRIOR_WEIGHT)
end

local function v145(v146, v147, v148)
    local v149 = #v146
    if v149 > 0 and math.random() < v143(v149) then
        local v150 = math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
        return math.max(0.02, v146[math.random(1, v149)] * math.exp(v68.JITTER * v150))
    end
    return v148 - v147 * math.log(1 - math.random())
end

local function v151(v152)
    local v153 = #v152
    if v153 > 0 and math.random() < v143(v153) then
        local v154 = v152[math.random(1, v153)]
        return math.random() < 0.5 and v154 or -v154
    end
    return (math.random() * 2 - 1) * math.pi
end

local function v155(v156, v157, v158, v159)
    for _ = 1, 24 do
        local v160 = v145(v156, v157, v158)
        if v160 > v159 then
            return v160 - v159
        end
    end
    return -v157 * math.log(1 - math.random()) * 0.5
end

local function v161(v162, v163)
    local v164 = v163 * v163
    local v165, v166 = 1, -1
    for v167, v168 in v162 do
        local v169 = 0
        for _, v170 in v162 do
            local v171, v172 = v168[1] - v170[1], v168[2] - v170[2]
            if v171 * v171 + v172 * v172 <= v164 then
                v169 += 1
            end
        end
        if v169 > v166 then
            v165, v166 = v167, v169
        end
    end
    local v173 = v162[v165]
    local v174, v175, v176 = 0, 0, 0
    for _, v177 in v162 do
        local v178, v179 = v173[1] - v177[1], v173[2] - v177[2]
        if v178 * v178 + v179 * v179 <= v164 then
            v174 += v177[1]
            v175 += v177[2]
            v176 += 1
        end
    end
    return v174 / v176, v175 / v176, v166 / #v162
end

local function v180(v181, v182, v183)
    local v184 = #v181
    local v185, v186, v187 = {}, {}, {}
    for v188, v189 in v181 do
        local v190, v191 = v189[1] - v182.X, v189[2] - v182.Z
        local v192 = math.max(math.sqrt(v190 * v190 + v191 * v191), v183 * 1.01)
        v185[v188] = math.atan2(v191, v190)
        v186[v188] = math.asin(v183 / v192)
        v187[v188] = v192
    end
    local v193, v194 = v185[1], -1
    for v195 = 1, v184 do
        local v196 = 0
        local v197 = v185[v195]
        for v198 = 1, v184 do
            if math.abs(v90(v197 - v185[v198])) <= v186[v198] then
                v196 += 1
            end
        end
        if v196 > v194 then
            v193, v194 = v197, v196
        end
    end
    local v199, v200 = -math.huge, math.huge
    local v201, v202 = 0, 0
    for v203 = 1, v184 do
        local v204 = v90(v185[v203] - v193)
        if math.abs(v204) <= v186[v203] then
            v199 = math.max(v199, v204 - v186[v203])
            v200 = math.min(v200, v204 + v186[v203])
            v201 += v187[v203]
            v202 += 1
        end
    end
    local v205 = v193
    if v199 <= v200 then
        v205 = v193 + (v199 + v200) / 2
    end
    local v206 = v201 / math.max(v202, 1)
    return v182.X + math.cos(v205) * v206, v182.Z + math.sin(v205) * v206, v194 / v184
end

function v68.aim(v207, v208, v209, v210)
    local v211 = v207.list
    local v212 = #v211
    if v212 == 0 then
        return nil
    end
    local v213 = v211[v212].t
    local v214 = v211[v212].p
    local v215, v216 = v68.fit(v207, v213, v68.FIT)
    local v217 = v68.velocity(v207, v213, 0.035).Y
    local v218 = math.abs(v217) > 6 or (not v207.grounded and v207.groundY ~= nil and v214.Y > v207.groundY + 0.5)
    local v219 = v68.GRAVITY
    local v220 = v207.groundY
    local v221 = v209 and v68.KNIFE_RAISE or v68.GUN_RAISE
    local function v222(v223)
        if not v218 then
            return v214.Y + v221
        end
        local v224 = v214.Y + v217 * v223 - 0.5 * v219 * v223 * v223
        if v220 and v224 < v220 then
            v224 = v220
        end
        return v224 + v221 * 0.5
    end
    local v225 = math.max(0, v210 + v68.INTERP + v68.PROCESS)
    if v212 < 8 then
        local v226 = v225
        if v209 then
            v226 = v225 + (v214 - v208).Magnitude / v209
        end
        return Vector3.new(v214.X + v215 * v226, v222(v226), v214.Z + v216 * v226), v226, 1
    end
    local v227 = v68.motion(v207)
    local v228 = v227.typical
    local v229 = v68.velocity(v207, v213, v68.SPAN)
    local v230 = v68.velocity(v207, v213 - v68.SPAN, v68.SPAN)
    local v231, v232 = (v229.X - v230.X) / v68.SPAN, (v229.Z - v230.Z) / v68.SPAN
    local v233 = math.sqrt(v215 * v215 + v216 * v216)
    local v234 = v233 > 0.5 and (v231 * v215 + v232 * v216) / v233 or 0
    local v235 = math.atan2(v216, v215)
    local v236 = v233
    if v227.state == "move" then
        local v237, v238 = v229.X + v231 * v68.ACCEL_LEAD, v229.Z + v232 * v68.ACCEL_LEAD
        local v239 = math.sqrt(v237 * v237 + v238 * v238)
        if math.sqrt(v231 * v231 + v232 * v232) > v68.ACCEL_MIN and v239 > v227.thr then
            v235 = math.atan2(v238, v237)
            if v233 < v228 * 0.85 and v239 > v233 then
                v236 = math.min(v239, v228)
            end
        end
        if v234 > v68.ACCEL_MIN and v233 < v228 * 0.85 then
            v236 = v228
        end
    end
    local v240 = (v227.stops + v68.STOP_PRIOR) / (v227.stops + v227.sharp + v68.STOP_PRIOR + v68.TURN_PRIOR)
    local v241
    if v227.state == "low" then
        local v242, v243 = v229.X + v231 * v68.ACCEL_LEAD, v229.Z + v232 * v68.ACCEL_LEAD
        local v244 = math.clamp((math.sqrt(v242 * v242 + v243 * v243) / v228 - 0.3) / 0.4, 0, 1)
        local v245 = v240 * (1 - 0.7 * v244)
        local v246 = (1 - v240) * (0.3 + 0.7 * v244)
        v240 = v245 / math.max(v245 + v246, 1e-6)
        if v244 > 0.5 then
            v241 = math.atan2(v243, v242)
        end
    end
    local v247 = (v227.stops + v68.STOP_PRIOR * 0.5) / (v227.events + v68.STOP_PRIOR * 0.5 + v68.TURN_PRIOR)
    local v248 = v227.ref or v235
    local v249 = v68.STEP
    local v250 = v209 and v225 + 1.6 or v225 + v249
    local v251 = {}
    local v252 = {}
    local v253 = v68.ACCEL_TAU
    for v254 = 1, v68.FUTURES do
        local v255, v256 = v214.X, v214.Z
        local v257, v258 = v215, v216
        local v259, v260, v261, v262
        local v263
        local v264 = v248
        if v227.state == "move" then
            v259, v260, v261 = true, v235, v236
            v263 = v155(v227.moveDur, v68.PRIOR_MOVE, 0.25, v227.elapsed)
        elseif v227.state == "low" then
            if math.random() < v240 then
                v259 = false
                v263 = v155(v227.stopDur, v68.PRIOR_STOP, 0.15, v227.elapsed)
            else
                local v265 = v151(v227.turnAngles)
                if math.abs(v265) < 1.6 then
                    v265 = math.pi
                end
                v259, v260, v261 = true, v241 or v248 + v265, v228
                v264 = v260
                v263 = v145(v227.moveDur, v68.PRIOR_MOVE, 0.25)
            end
        else
            v259 = false
            v262 = v233 < v227.thr
            v263 = v155(v227.stopDur, v68.PRIOR_STOP, 0.15, v227.elapsed)
        end
        local v266 = 0
        local v267
        local function v268(v269)
            local v270, v271 = 0, 0
            if v259 then
                v270, v271 = math.cos(v260) * v261, math.sin(v260) * v261
            elseif v262 then
                v270, v271 = v215, v216
            end
            local v272 = math.exp(-v269 / v253)
            local v273 = v253 * (1 - v272)
            v255 += v270 * v269 + (v257 - v270) * v273
            v256 += v271 * v269 + (v258 - v271) * v273
            v257 = v270 + (v257 - v270) * v272
            v258 = v271 + (v258 - v271) * v272
        end
        while v266 < v250 do
            local v274 = math.min(v249, v250 - v266)
            if not v209 and v266 + v274 > v225 then
                v274 = v225 - v266
            end
            local v275 = v274
            while v263 < v275 do
                v268(v263)
                v275 -= v263
                if v259 then
                    if math.random() < v247 then
                        v259 = false
                        v262 = false
                        v264 = v260
                        v263 = v145(v227.stopDur, v68.PRIOR_STOP, 0.15)
                    else
                        v260 += v151(v227.turnAngles)
                        v263 = v145(v227.moveDur, v68.PRIOR_MOVE, 0.25)
                    end
                else
                    v259 = true
                    v262 = false
                    v260 = v264 + v151(v227.startAngles)
                    v261 = v228
                    v263 = v145(v227.moveDur, v68.PRIOR_MOVE, 0.25)
                end
            end
            v268(v275)
            v263 -= v275
            v266 += v274
            if v209 then
                if v266 >= v225 then
                    local v276, v277 = v255 - v208.X, v256 - v208.Z
                    if math.sqrt(v276 * v276 + v277 * v277) <= v209 * (v266 - v225) then
                        v267 = { v255, v256 }
                        v252[v254] = v266
                        break
                    end
                end
            elseif v266 >= v225 - 1e-9 then
                v267 = { v255, v256 }
                v252[v254] = v266
                break
            end
        end
        v251[v254] = v267 or { v255, v256 }
        v252[v254] = v252[v254] or v266
    end
    local v278, v279, v280
    if v209 then
        v278, v279, v280 = v180(v251, v208, v68.KNIFE_RADIUS)
    else
        v278, v279, v280 = v161(v251, v68.GUN_RADIUS)
    end
    local v281 = v225
    if v209 then
        local v282, v283 = 0, 0
        for v284 = 1, #v251 do
            local v285, v286 = v251[v284][1] - v278, v251[v284][2] - v279
            if v285 * v285 + v286 * v286 <= v68.KNIFE_RADIUS ^ 2 then
                v282 += v252[v284]
                v283 += 1
            end
        end
        v281 = v283 > 0 and v282 / v283 or v225
    end
    return Vector3.new(v278, v222(v281), v279), v281, v280
end

function v68.ready(v287, v288, v289)
    if v287 then
        return v288 >= v68.KNIFE_SURE or v289 >= v68.KNIFE_HOLD
    end
    return v288 >= v68.GUN_SURE or v289 >= v68.GUN_HOLD
end

function v68.newCalibration()
    local v290 = { score = {}, shots = 0 }
    local v291 = 0
    local v292 = v68.OFFSET_MIN
    while v292 <= v68.OFFSET_MAX + 1e-9 do
        v291 += 1
        local v293 = (v292 - v68.OFFSET_PRIOR) / v68.OFFSET_SPREAD
        v290.score[v291] = -0.5 * v293 * v293
        v292 += v68.OFFSET_STEP
    end
    return v290
end

function v68.observeThrow(v294, v295, v296, v297, v298, v299, v300, v301)
    local v302 = v295.list
    if #v302 < 2 then
        return false
    end
    local v303 = v302[#v302].t
    local v304 = v299 - v298
    local v305, v306 = v304.X, v304.Z
    local v307 = math.sqrt(v305 * v305 + v306 * v306)
    if v307 < 0.5 then
        return false
    end
    v305, v306 = v305 / v307, v306 / v307
    local v308 = v68.KNIFE_RADIUS + 0.2
    local v309 = {}
    local v310 = 0
    local v311 = v68.OFFSET_MIN
    while v311 <= v68.OFFSET_MAX + 1e-9 do
        v310 += 1
        local v312 = false
        local v313 = false
        local v314 = 0
        while v314 <= 1.2 do
            local v315 = v296 + v297 + v311 + v314
            if v315 > v303 then
                break
            end
            v313 = true
            local v316 = v68.at(v295, v315)
            local v317, v318 = v298.X + v305 * v300 * v314, v298.Z + v306 * v300 * v314
            local v319, v320 = v316.X - v317, v316.Z - v318
            if v319 * v319 + v320 * v320 <= v308 * v308 then
                v312 = true
                break
            end
            v314 += 1 / 60
        end
        if not v313 then
            v309[v310] = 0.5
        elseif v301 then
            v309[v310] = v312 and 0.9 or 0.15
        else
            v309[v310] = v312 and 0.2 or 0.85
        end
        v311 += v68.OFFSET_STEP
    end
    local v321, v322 = math.huge, -math.huge
    for _, v323 in v309 do
        v321 = math.min(v321, v323)
        v322 = math.max(v322, v323)
    end
    if v322 - v321 < 0.3 then
        return false
    end
    for v324, v325 in v309 do
        v294.score[v324] += math.log(v325)
    end
    v294.shots += 1
    return true
end

function v68.observeShot(v326, v327, v328, v329, v330, v331, v332)
    local v333 = v327.list
    if #v333 < 2 then
        return false
    end
    local v334 = v333[#v333].t
    local v335 = v331 - v330
    local v336, v337 = v335.X, v335.Z
    local v338 = math.sqrt(v336 * v336 + v337 * v337)
    if v338 < 0.5 then
        return false
    end
    v336, v337 = v336 / v338, v337 / v338
    local v339 = false
    local v340 = {}
    local v341 = 0
    local v342 = v68.OFFSET_MIN
    while v342 <= v68.OFFSET_MAX + 1e-9 do
        v341 += 1
        local v343 = v328 + v329 + v342
        local v344 = v68.at(v327, v343)
        local v345
        if v343 > v334 then
            v345 = 0.5
        elseif v332 then
            local v346, v347 = v344.X - v331.X, v344.Z - v331.Z
            local v348 = math.sqrt(v346 * v346 + v347 * v347)
            local v349 = math.max(0, v348 - 1.3)
            v345 = 0.08 + 0.92 * math.exp(-v349 * v349 / 0.32)
        else
            local v350, v351 = v344.X - v330.X, v344.Z - v330.Z
            local v352 = v350 * v336 + v351 * v337
            local v353 = math.abs(v350 * v337 - v351 * v336)
            if v352 > 0 and v352 < v338 + 2 and v353 < 1.0 then
                v345 = 0.25
            else
                v345 = 0.85
            end
        end
        v340[v341] = v345
        v342 += v68.OFFSET_STEP
    end
    local v354, v355 = math.huge, -math.huge
    for _, v356 in v340 do
        v354 = math.min(v354, v356)
        v355 = math.max(v355, v356)
    end
    v339 = v355 - v354 > 0.3
    if not v339 then
        return false
    end
    for v357, v358 in v340 do
        v326.score[v357] += math.log(v358)
    end
    v326.shots += 1
    return true
end

function v68.offset(v359)
    if v359.shots < v68.LEARN_AFTER then
        return nil
    end
    local v360, v361 = 1, -math.huge
    for v362, v363 in v359.score do
        if v363 > v361 then
            v360, v361 = v362, v363
        end
    end
    return v68.OFFSET_MIN + (v360 - 1) * v68.OFFSET_STEP
end

function v68.apply(v364)
    local v365 = v68.offset(v364)
    if v365 then
        v68.INTERP = math.clamp(v365 - v68.PROCESS, v68.OFFSET_MIN, v68.OFFSET_MAX)
    end
    return v365
end

local v366 = 96
v12(v5:GetInstanceAddedSignal("ThrowingKnife"):Connect(function(v367)
    local v368 = v367:GetAttribute("ThrowSpeed")
    if type(v368) == "number" and v368 > 0 then
        v366 = v368
    end
end))

local v369 = 0.12
local function v370()
    local v371, v372 = pcall(function()
        return v6.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if v371 and type(v372) == "number" and v372 > 0 then
        return v372 / 1000
    end
    local v373, v374 = pcall(v8.GetNetworkPing, v8)
    if v373 and type(v374) == "number" and v374 > 0 then
        return v374 * 2
    end
    return nil
end
task.spawn(function()
    while not v10 do
        local v375 = v370()
        if v375 then
            v369 += (math.clamp(v375, 0, 0.6) - v369) * 0.35
        end
        v68.GRAVITY = v7.Gravity
        task.wait(0.5)
    end
end)

local v376 = v7.Raycast
local v377 = RaycastParams.new()
v377.FilterType = Enum.RaycastFilterType.Exclude
local function v378()
    local v379 = {}
    for _, v380 in v1:GetPlayers() do
        if v380.Character then
            table.insert(v379, v380.Character)
        end
    end
    for _, v381 in v5:GetTagged("WeaponPassthrough") do
        table.insert(v379, v381)
    end
    v377.FilterDescendantsInstances = v379
end
v378()

local v382 = {}
local v383 = { kind = nil, tool = nil, remote = nil, attachment = nil }
local v384
local v385 = {}
local v386
local v387

local v388 = 3
local v389 = v9.__MM2Cal
if type(v389) ~= "table" or v9.__MM2CalJob ~= game.JobId or v9.__MM2CalVersion ~= v388 then
    v389 = v68.newCalibration()
    v9.__MM2Cal, v9.__MM2CalJob, v9.__MM2CalVersion = v389, game.JobId, v388
end
local function v390()
    v68.apply(v389)
end
v390()

local function v391(v392)
    return (v392 == "Gun" and v15.GunAim) or (v392 == "Knife" and v15.KnifeAim)
end

local function v393()
    local v394 = v8.Character
    local v395 = v394 and v394:FindFirstChildOfClass("Tool")
    if v395 == v383.tool and (not v395 or v383.remote and v383.remote.Parent) then
        return
    end
    v383.tool, v383.kind, v383.remote = v395, nil, nil
    if v395 then
        if v28(v395) then
            local v396 = v395:FindFirstChild("Events")
            v383.kind = "Knife"
            v383.remote = v396 and v396:FindFirstChild("KnifeThrown")
        elseif v25(v395) then
            v383.kind = "Gun"
            v383.remote = v395:FindFirstChild("Shoot")
        end
    end
    local v397 = v394 and v394:FindFirstChild("HumanoidRootPart")
    v383.attachment = v397 and v397:FindFirstChild("GunRaycastAttachment")
end

local function v398(v399, v400)
    for _, v401 in { "HumanoidRootPart", "Head", "UpperTorso", "Torso" } do
        local v402 = v400:FindFirstChild(v401)
        if v402 then
            local v403 = v376(v7, v399, v402.Position - v399, v377)
            if not v403 then
                return true
            end
            if v403.Instance.Transparency >= 1 and v50(v399, v402.Position, v400) then
                return true
            end
        end
    end
    return false
end

local function v404(v405)
    table.clear(v385)
    local v406 = v41(v8)
    if not v406 then
        return nil
    end
    local v407 = v7.CurrentCamera
    local v408 = v65()
    local v409 = math.max(v407.ViewportSize.Y * 0.45, 220)
    local v410 = v8.Character:FindFirstChild("Head")
    local v411 = v410 and v410.Position or v406.Position
    local v412, v413, v414, v415 = false, nil, nil, nil
    for _, v416 in v1:GetPlayers() do
        if v416 ~= v8 then
            local v417, _, v418 = v41(v416)
            local v419, v420 = v35(v416)
            if v417 and not v420 then
                if v419 == "Murderer" then
                    v412 = true
                end
                local v421, v422 = v407:WorldToViewportPoint(v417.Position)
                if v422 and v421.Z > 0 then
                    local v423 = (Vector2.new(v421.X, v421.Y) - v408).Magnitude
                    if v423 <= v409 and v398(v411, v418) then
                        local v424 = v419 == "Sheriff" or v419 == "Hero"
                        local v425 = { plr = v416, root = v417, char = v418, off = v423 / v409, priority = v424 }
                        if v419 == "Murderer" then
                            v413 = v425
                        end
                        table.insert(v385, v425)
                        local v426 = v423
                        if v405 == "Knife" and v424 then
                            v426 -= 40
                        end
                        if v384 and v384.plr == v416 then
                            v426 -= 25
                        end
                        if not v415 or v426 < v415 then
                            v414, v415 = v425, v426
                        end
                    end
                end
            end
        end
    end
    if v405 == "Gun" and v412 then
        table.clear(v385)
        if v413 then
            table.insert(v385, v413)
        end
        return v413
    end
    return v414
end

local function v427(v428, v429)
    local v430 = v376(v7, v428, v429 - v428, v377)
    return not v430 or v430.Instance.Transparency >= 1
end

local function v431(v432, v433, v434)
    if not v432 or not v432.root.Parent then
        return nil
    end
    local v435 = v382[v432.plr]
    if not v435 or v435.root ~= v432.root or #v435.list < 2 then
        return nil
    end
    local v436, _, v437 = v68.aim(v435, v434, v433 == "Knife" and v366 or nil, v369)
    if not v436 then
        return nil
    end
    local v438 = v435.list[#v435.list].p
    local v439 = v436 - v438
    if v439.Magnitude > 0.5 then
        local v440 = v376(v7, v438, v439, v377)
        if v440 and v440.Instance.CanCollide then
            v436 = v440.Position - v439.Unit * 1.5
        end
    end
    if not v427(v434, v436) then
        for _, v441 in { 0.8, -1.0, -2.0 } do
            local v442 = v436 + Vector3.new(0, v441, 0)
            if v427(v434, v442) then
                v436 = v442
                break
            end
        end
    end
    return v436, v437
end

local function v443(v444, v445)
    if v444 == "Knife" and #v385 > 1 then
        local v446, v447, v448, v449
        for _, v450 in v385 do
            local v451, v452 = v431(v450, v444, v445)
            if v451 then
                local v453 = v452 - 0.25 * v450.off + (v450.priority and 0.08 or 0)
                if not v449 or v453 > v449 then
                    v446, v447, v448, v449 = v450, v451, v452, v453
                end
            end
        end
        if v446 then
            return v447, v448, v446
        end
    end
    local v454, v455 = v431(v384, v444, v445)
    return v454, v455, v384
end

local function v456(v457, v458, v459)
    if v457 == "Gun" then
        local v460 = v459 - v458
        if v460.Magnitude > 0.1 then
            return CFrame.new(v459 + v460.Unit * 4)
        end
    end
    return CFrame.new(v459)
end

local function v461(v462, v463)
    if typeof(v463) == "CFrame" then
        return v463.Position
    end
    if v462 == "Gun" and v383.attachment then
        return v383.attachment.WorldPosition
    end
    local v464 = v383.tool and v383.tool:FindFirstChild("Handle")
    return v464 and v464.Position
end

local function v465(v466, v467)
    local v468 = v466.FireServer
    return v468(v466, table.unpack(v467, 1, v467.n))
end

local function v469(v470, v471, v472, v473)
    local v474 = v471 and v382[v471.plr]
    if not v474 then
        return
    end
    local v475 = { kind = v470, t = os.clock(), rtt = v369, origin = v472, aim = v473, rec = v474, char = v471.char, tool = v383.tool }
    if v470 == "Gun" then
        v387 = v475
        return
    end
    task.delay(1.9, function()
        if v10 then
            return
        end
        local v476 = v474.deadAt
        local v477 = v476 ~= nil and v476 >= v475.t and v476 <= v475.t + 1.7
        if v68.observeThrow(v389, v474, v475.t, v475.rtt, v475.origin, v475.aim, v366, v477) then
            v390()
        end
    end)
end

local function v478(v479, v480, v481, v482)
    local v483 = v387
    if not v483 or v479 ~= v483.tool or typeof(v481) ~= "Vector3" or os.clock() - v483.t > 1.5 then
        return
    end
    v387 = nil
    local v484 = v483.origin
    if typeof(v480) == "Vector3" then
        v484 = v480
    elseif typeof(v480) == "Instance" then
        if v480:IsA("Attachment") then
            v484 = v480.WorldPosition
        elseif v480:IsA("BasePart") then
            v484 = v480.Position
        end
    end
    local v485 = typeof(v482) == "Instance" and v483.char ~= nil and v482:IsDescendantOf(v483.char)
    task.delay(1.1, function()
        if v10 then
            return
        end
        if v68.observeShot(v389, v483.rec, v483.t, v483.rtt, v484, v481, v485) then
            v390()
        end
    end)
end
task.spawn(function()
    local v486 = v3:WaitForChild("ClientServices", 10)
    local v487 = v486 and v486:WaitForChild("WeaponService", 10)
    local v488 = v487 and v487:WaitForChild("GunFired", 10)
    if v488 and not v10 then
        v12(v488.OnClientEvent:Connect(function(...)
            pcall(v478, ...)
        end))
    end
end)

local function v489(v490)
    v386 = nil
    local v491 = v490.args
    if v490.kind == "Gun" and v383.attachment and typeof(v491[1]) == "CFrame" then
        v491[1] = v383.attachment.WorldCFrame
    end
    local v492 = v461(v490.kind, v491[1]) or v490.origin
    local v493, _, v494 = v443(v490.kind, v492)
    if v493 then
        v491[2] = v456(v490.kind, v492, v493)
    elseif v490.aim then
        v491[2] = v490.aim
    end
    if pcall(v465, v490.remote, v491) and typeof(v491[2]) == "CFrame" then
        v469(v490.kind, v494 or v490.entry, v492, v491[2].Position)
    end
end

local v495 = 0
v12(v2.PreSimulation:Connect(function()
    if v10 then
        return
    end
    if not (v15.GunAim or v15.KnifeAim) then
        if next(v382) then
            table.clear(v382)
        end
        v384 = nil
        table.clear(v385)
        if v386 then
            v489(v386)
        end
        return
    end
    local v496 = os.clock()
    for _, v497 in v1:GetPlayers() do
        if v497 ~= v8 then
            local v498 = v497.Character
            local v499 = v498 and v498:FindFirstChild("HumanoidRootPart")
            local v500 = v498 and v498:FindFirstChildOfClass("Humanoid")
            if v499 and v500 then
                local v501 = v382[v497]
                if not v501 or v501.root ~= v499 then
                    v501 = v68.new()
                    v501.root = v499
                    v382[v497] = v501
                end
                if v500.Health <= 0 then
                    v501.deadAt = v501.deadAt or v496
                end
                if not v501.deadAt or v496 - v501.deadAt < 0.6 then
                    local v502 = v500:GetState()
                    local v503 = v500.FloorMaterial ~= Enum.Material.Air
                        or (v502 ~= Enum.HumanoidStateType.Freefall and v502 ~= Enum.HumanoidStateType.Jumping)
                    v68.push(v501, v496, v499.Position, v503)
                end
            else
                v382[v497] = nil
            end
        end
    end
    v495 += 1
    if v495 % 60 == 0 then
        v378()
    end
    v393()
    if v383.kind and v391(v383.kind) then
        v384 = v404(v383.kind)
    else
        v384 = nil
        table.clear(v385)
    end
    local v504 = v386
    if v504 then
        if v504.remote ~= v383.remote or not v384 then
            v489(v504)
        else
            local v505 = v461(v504.kind, v383.attachment and v383.attachment.WorldCFrame) or v504.origin
            local _, v506 = v443(v504.kind, v505)
            if not v506 or v68.ready(v504.kind == "Knife", v506, v496 - v504.start) then
                v489(v504)
            end
        end
    end
end))
v12(v1.PlayerRemoving:Connect(function(v507)
    v382[v507] = nil
end))

local function v508(v509, v510)
    local v511 = v383.kind
    local v512 = v461(v511, v510[1])
    if not v512 then
        return false
    end
    local v513, v514, v515 = v443(v511, v512)
    if not v513 then
        return false
    end
    local v516 = v456(v511, v512, v513)
    if not v68.ready(v511 == "Knife", v514, 0) then
        if v386 then
            v489(v386)
        end
        v386 = { remote = v509, args = v510, kind = v511, origin = v512, aim = v516, entry = v515, start = os.clock() }
        return true
    end
    v510[2] = v516
    v465(v509, v510)
    v469(v511, v515, v512, v516.Position)
    return true
end

local v517 = false
if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local v518
    local v519 = typeof(checkcaller) == "function" and checkcaller or function()
        return false
    end
    local function v520(self, ...)
        if v10 or self ~= v383.remote then
            return v518(self, ...)
        end
        if getnamecallmethod() ~= "FireServer" or v519() or not v391(v383.kind) then
            return v518(self, ...)
        end
        local v521 = table.pack(...)
        local v522, v523 = pcall(v508, self, table.pack(...))
        if v522 and v523 then
            return nil
        end
        return v465(self, v521)
    end
    if typeof(newcclosure) == "function" then
        v520 = newcclosure(v520)
    end
    v518 = hookmetamethod(game, "__namecall", v520)
    v517 = true
end

local v524
pcall(function()
    v524 = require(v3:WaitForChild("ClientServices", 5):WaitForChild("WeaponService", 5))
end)
local v525, v526
if not v517 and type(v524) == "table" then
    v525, v526 = v524.GetMouseTargetCFrame, v524.GetTargetPosition
    local function v527()
        local v528 = v383.kind
        if v10 or not v528 or not v391(v528) then
            return nil
        end
        local v529 = v461(v528)
        local v530 = v529 and v443(v528, v529)
        return v530 and v456(v528, v529, v530)
    end
    v524.GetMouseTargetCFrame = function(self, ...)
        local v531, v532 = pcall(v527)
        if v531 and v532 then
            return v532
        end
        return v525(self, ...)
    end
    v524.GetTargetPosition = function(self, v533, v534, ...)
        v58, v59 = Vector2.new(v533, v534), os.clock()
        local v535, v536 = pcall(v527)
        if v535 and v536 then
            return v536
        end
        return v526(self, v533, v534, ...)
    end
end

local v537 = Instance.new("Folder")
v537.Name = "\0"
v537.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
local v538 = {}
local v539 = {
    Murderer = Color3.fromRGB(255, 50, 50),
    Sheriff = Color3.fromRGB(50, 140, 255),
    Hero = Color3.fromRGB(50, 140, 255),
    Innocent = Color3.fromRGB(60, 230, 90),
}
local function v540(v541)
    local v542 = v538[v541]
    if v542 then
        v542.hl:Destroy()
        v542.bb:Destroy()
        v538[v541] = nil
    end
end
v12(v1.PlayerRemoving:Connect(v540))
local function v543()
    for _, v544 in v1:GetPlayers() do
        if v544 ~= v8 then
            local v545, _, v546 = v41(v544)
            local v547, v548 = v35(v544)
            if v15.Esp and v545 and not v548 then
                local v549 = v539[v547] or v539.Innocent
                local v550 = v538[v544]
                if not v550 or v550.char ~= v546 then
                    v540(v544)
                    local v551 = Instance.new("Highlight")
                    v551.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    v551.FillTransparency = 0.55
                    v551.OutlineTransparency = 0
                    v551.Adornee = v546
                    v551.Parent = v537
                    local v552 = Instance.new("BillboardGui")
                    v552.AlwaysOnTop = true
                    v552.Size = UDim2.fromOffset(160, 22)
                    v552.StudsOffset = Vector3.new(0, 3.4, 0)
                    v552.Adornee = v545
                    v552.Parent = v537
                    local v553 = Instance.new("TextLabel")
                    v553.BackgroundTransparency = 1
                    v553.Size = UDim2.fromScale(1, 1)
                    v553.Font = Enum.Font.GothamBold
                    v553.TextSize = 13
                    v553.TextStrokeTransparency = 0.4
                    v553.Text = v544.DisplayName
                    v553.Parent = v552
                    v550 = { hl = v551, bb = v552, label = v553, char = v546 }
                    v538[v544] = v550
                end
                if v550.color ~= v549 then
                    v550.color = v549
                    v550.hl.FillColor = v549
                    v550.hl.OutlineColor = v549
                    v550.label.TextColor3 = v549
                end
            else
                v540(v544)
            end
        end
    end
end
task.spawn(function()
    while not v10 do
        pcall(v543)
        task.wait(0.25)
    end
end)

local v554 = {}
local v555 = {}
local v556
local function v557(v558)
    local v559 = v555[v558]
    if v559 then
        return v559
    end
    local v560 = {}
    for _, v561 in v558:GetDescendants() do
        if v561:IsA("BasePart") then
            table.insert(v560, v561)
        end
    end
    v555[v558] = v560
    local v562
    v562 = v558.DescendantAdded:Connect(function(v563)
        if v563:IsA("BasePart") then
            table.insert(v560, v563)
        end
    end)
    v558.AncestryChanged:Once(function()
        v555[v558] = nil
        v562:Disconnect()
    end)
    return v560
end
v12(v2.PreSimulation:Connect(function()
    if not v15.AntiFling then
        v556 = nil
        return
    end
    local v564, v565 = v41(v8)
    local v566 = os.clock()
    for _, v567 in v1:GetPlayers() do
        if v567 ~= v8 then
            local v568 = v567.Character
            local v569 = v568 and v568:FindFirstChild("HumanoidRootPart")
            if v569 and v564 then
                local v570 = v569.Position - v564.Position
                if v570.X * v570.X + v570.Y * v570.Y + v570.Z * v570.Z < 3600 then
                    local v571 = v569.AssemblyAngularVelocity
                    local v572 = v569.AssemblyLinearVelocity
                    if v571:Dot(v571) > 625 or v572:Dot(v572) > 14400 then
                        v554[v567] = v566 + 3
                    end
                end
            end
            local v573 = v554[v567]
            if v573 then
                if v566 > v573 or not v568 then
                    v554[v567] = nil
                else
                    for _, v574 in v557(v568) do
                        if v574.CanCollide then
                            v574.CanCollide = false
                        end
                    end
                end
            end
        end
    end
    if not v564 then
        v556 = nil
        return
    end
    local v575 = v564.AssemblyLinearVelocity
    local v576 = math.sqrt(v575.X * v575.X + v575.Z * v575.Z)
    local v577 = v564.AssemblyAngularVelocity.Magnitude
    local v578 = v565.WalkSpeed
    if (v576 > math.max(v578 * 5, 90) or v575.Y > 140 or v577 > 35) and v556 then
        v564.AssemblyLinearVelocity = Vector3.zero
        v564.AssemblyAngularVelocity = Vector3.zero
        v564.CFrame = v556
    elseif v576 < v578 * 2 + 4 and v577 < 8 and math.abs(v575.Y) < 60 then
        v556 = v564.CFrame
    end
end))

local v579 = v14:CreateWindow({
    Name = "MM2",
    Author = "ily",
    Icon = "swords",
    SideBarWidth = 130,
    ToggleKey = Enum.KeyCode.K,
    Size = UDim2.fromOffset(460, 300),
    Elements = {
        Minimized = false,
        Close = false,
    },
})

local v580 = "\u{200B}\u{200C}\u{200B}"
pcall(function()
    v579:EditOpenButton({
        Title = v580,
        Icon = "",
        Transparency = 1,
        StrokeThickness = 0,
    })
end)
local v581 = {}
local function v582()
    local v583 = { game:GetService("CoreGui") }
    if typeof(gethui) == "function" then
        table.insert(v583, gethui())
    end
    local v584 = v8:FindFirstChildOfClass("PlayerGui")
    if v584 then
        table.insert(v583, v584)
    end
    local v585 = false
    for _, v586 in v583 do
        local v587, v588 = pcall(v586.GetDescendants, v586)
        if v587 then
            for _, v589 in v588 do
                if (v589:IsA("TextLabel") or v589:IsA("TextButton")) and v589.Text == v580 then
                    local v590 = v589
                    local v591 = v589.Parent
                    while v591 and v591:IsA("GuiObject") and v591.AbsoluteSize.X * v591.AbsoluteSize.Y < 320 * 160 do
                        v590 = v591
                        v591 = v591.Parent
                    end
                    if v590:IsA("GuiObject") and not v581[v590] then
                        v581[v590] = true
                        v590.Visible = false
                        v12(v590:GetPropertyChangedSignal("Visible"):Connect(function()
                            if v590.Visible then
                                v590.Visible = false
                            end
                        end))
                    end
                    v585 = true
                end
            end
        end
    end
    return v585
end
task.spawn(function()
    for _, v592 in { 0.2, 0.5, 1, 2, 4, 8 } do
        task.wait(v592)
        if v10 then
            return
        end
        local v593, v594 = pcall(v582)
        if v593 and v594 then
            return
        end
    end
end)
local v595 = Enum.KeyCode.K
v12(v4.InputBegan:Connect(function(v596)
    if v596.KeyCode == v595 then
        task.delay(0.15, pcall, v582)
        task.delay(0.6, pcall, v582)
    end
end))

local v597 = v579:Tab({ Title = "Main", Icon = "crosshair" })
v597:Section({ Title = "Silent Aim" })
v597:Toggle({
    Title = "Gun Silent Aim",
    Default = false,
    Callback = function(v598)
        v15.GunAim = v598
    end,
})
v597:Toggle({
    Title = "Murderer Silent Aim",
    Default = false,
    Callback = function(v599)
        v15.KnifeAim = v599
    end,
})
v597:Section({ Title = "Other" })
v597:Toggle({
    Title = "ESP",
    Default = false,
    Callback = function(v600)
        v15.Esp = v600
    end,
})
v597:Toggle({
    Title = "Anti Fling",
    Default = false,
    Callback = function(v601)
        v15.AntiFling = v601
        if not v601 then
            table.clear(v554)
        end
    end,
})

local v602 = v579:Tab({ Title = "Settings", Icon = "settings" })
local v603 = v602:Keybind({
    Title = "Toggle UI",
    Callback = function(v604)
        local v605 = typeof(v604) == "EnumItem" and v604 or Enum.KeyCode[tostring(v604)]
        if v605 then
            v595 = v605
            pcall(v579.SetToggleKey, v579, v605)
        end
    end,
})
pcall(function()
    v603:SetValue("K")
end)

v9.__CustomMM2Unload = function()
    v10 = true
    if v386 then
        pcall(v489, v386)
    end
    for _, v606 in v11 do
        pcall(v606.Disconnect, v606)
    end
    for v607 in v538 do
        v540(v607)
    end
    v537:Destroy()
    if v525 and v524 then
        v524.GetMouseTargetCFrame = v525
        v524.GetTargetPosition = v526
    end
    pcall(v579.Close, v579)
end
