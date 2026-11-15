local v1 = game:GetService("Players")
local v2 = game:GetService("RunService")
local v3 = game:GetService("ReplicatedStorage")
local v4 = game:GetService("UserInputService")
local v5 = game:GetService("CollectionService")
local v6 = game:GetService("Stats")
local v7 = workspace
local v8 = v1.LocalPlayer

local v9 = (typeof(getgenv) == "function" and getgenv()) or _G
if v9.__c43 then
    pcall(v9.__c43)
end

local v10 = false
local v11 = {}
local function v12(v13)
    table.insert(v11, v13)
    return v13
end

local v14 = loadstring(game:HttpGet("https://github.com/SSHRKs/LumeUI/releases/latest/download/main.lua"))()

local v15 = {
    k13 = false,
    k20 = false,
    k5 = false,
    k4 = false,
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
    k42 = 3.0,
    k34 = 0.034,
    k6 = 0.067,
    k8 = 196.2,
    k14 = 0.06,
    k33 = 0.01,
    k7 = 64,
    k35 = 1 / 30,
    k23 = 2.0,
    k22 = 0.4,
    k39 = 0.7,
    k29 = 0.12,
    k30 = 1.5,
    k31 = 0.8,
    k32 = 1.5,
    k36 = 0.5,
    k41 = 0.7,
    k38 = 3,
    k37 = 0.9,
    k15 = 0.2,
    k1 = 0.05,
    k2 = 40,
    k40 = 0.035,
    k3 = 0.05,
    k10 = 1.0,
    k17 = 1.2,
    k9 = 0.3,
    k12 = 0.85,
    k16 = 0.35,
    k19 = 0.75,
    k11 = 1.0,
    k18 = 1.5,
    k25 = -0.3,
    k24 = 0.4,
    k28 = 0.005,
    k26 = 0.07,
    k27 = 0.12,
    k21 = 2,
}

function v68.new()
    return { k65 = {}, k60 = nil, k61 = true }
end

function v68.k78(v69, v70, v71, v72)
    local v73 = v69.k65
    local v74 = #v73
    if v74 > 0 and v70 <= v73[v74].k94 then
        return
    end
    v73[v74 + 1] = { k94 = v70, k75 = v71 }
    v74 += 1
    if v72 then
        v69.k60 = v71.Y
    end
    v69.k61 = v72
    local v75 = v70 - v68.k42 - 0.2
    local v76 = 0
    while v76 < v74 - 2 and v73[v76 + 1].k94 < v75 do
        v76 += 1
    end
    if v76 > 0 then
        table.move(v73, v76 + 1, v74, 1)
        for v77 = v74 - v76 + 1, v74 do
            v73[v77] = nil
        end
    end
end

function v68.k50(v78, v79)
    local v80 = v78.k65
    local v81 = #v80
    if v79 >= v80[v81].k94 then
        return v80[v81].k75
    end
    if v79 <= v80[1].k94 then
        return v80[1].k75
    end
    local v82, v83 = 1, v81
    while v83 - v82 > 1 do
        local v84 = (v82 + v83) // 2
        if v80[v84].k94 <= v79 then
            v82 = v84
        else
            v83 = v84
        end
    end
    local v85, v86 = v80[v82], v80[v83]
    return v85.k75 + (v86.k75 - v85.k75) * ((v79 - v85.k94) / math.max(v86.k94 - v85.k94, 1e-6))
end

function v68.k99(v87, v88, v89)
    return (v68.k50(v87, v88) - v68.k50(v87, v88 - v89)) / v89
end

local function v90(v91)
    v91 = (v91 + math.pi) % (2 * math.pi)
    return v91 - math.pi
end

function v68.k59(v92, v93, v94)
    local v95, v96, v97, v98, v99, v100, v101 = 0, 0, 0, 0, 0, 0, 0
    for v102 = 0, 4 do
        local v103 = -v94 * v102 / 4
        local v104 = v68.k50(v92, v93 + v103)
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

function v68.k67(v106)
    local v107 = v106.k65
    local v108 = v107[#v107].k94
    local v109 = math.max(v107[1].k94 + v68.k34, v108 - v68.k42)
    local v110 = {}
    local v111 = v109
    while v111 <= v108 + 1e-6 do
        local v112 = v68.k99(v106, v111, v68.k34)
        v110[#v110 + 1] = { k94 = v111, k100 = v112.X, k101 = v112.Z, k85 = math.sqrt(v112.X * v112.X + v112.Z * v112.Z) }
        v111 += 1 / 60
    end
    local v113 = {}
    for _, v114 in v110 do
        if v114.k85 > v68.k23 then
            v113[#v113 + 1] = v114.k85
        end
    end
    table.sort(v113)
    local v115 = #v113 >= 6 and v113[math.max(1, math.floor(#v113 * 0.7))] or 16
    local v116 = math.max(v68.k23, v115 * v68.k22)
    local v117 = v68.k3
    local v118 = v117 * math.log(1 / v68.k22) + v68.k34 / 2
    local v119 = v117 * math.log(1 / (1 - v68.k22)) + v68.k34 / 2
    local v120 = {
        k68 = {}, k92 = {}, k97 = {}, k90 = {},
        k93 = 0, k87 = 0, k58 = 0,
        k98 = v115, k95 = v116,
    }
    local v121, v122, v123, v124, v125, v126
    local v127, v128, v129
    local v130 = {}
    for _, v131 in v110 do
        local v132 = v131.k85 > v116
        local v133 = v132 and math.atan2(v131.k101, v131.k100) or nil
        if not v121 then
            v121 = v132 and "move" or "stop"
            v122, v123 = v131.k94, false
            if v132 then
                v124 = v133
                v125, v126 = math.cos(v133), math.sin(v133)
            end
        elseif v121 == "move" then
            if v132 then
                table.insert(v130, v131)
                local v134 = v90(v133 - v124)
                if math.abs(v134) > v68.k39 then
                    local v135 = math.abs(v134) / 2
                    local v136 = v131.k94
                    for _, v137 in v130 do
                        local v138 = v137.k100 * v125 + v137.k101 * v126
                        local v139 = math.abs(v137.k100 * v126 - v137.k101 * v125)
                        if math.atan2(v139, v138) >= v135 then
                            v136 = v137.k94
                            break
                        end
                    end
                    v136 -= v68.k40 + v68.k34 / 2
                    if v123 then
                        table.insert(v120.k68, v136 - v122)
                    end
                    table.insert(v120.k97, v134)
                    v120.k58 += 1
                    if math.abs(v134) > 1.6 then
                        v120.k87 += 1
                    end
                    v122, v123 = v136, true
                    v124 = v133
                    v125, v126 = math.cos(v133), math.sin(v133)
                    v130 = {}
                end
            else
                v121 = "low"
                v127 = v131.k94
                v128 = v131.k94 - v118
                v129 = v124
            end
        elseif v121 == "low" then
            if v132 then
                local v140 = v90(v133 - v129)
                if v131.k94 - v127 < v68.k29 then
                    if math.abs(v140) > v68.k39 then
                        local v141 = (v128 + v131.k94 - v119) / 2
                        if v123 then
                            table.insert(v120.k68, v141 - v122)
                        end
                        table.insert(v120.k97, v140)
                        v120.k58 += 1
                        if math.abs(v140) > 1.6 then
                            v120.k87 += 1
                        end
                        v122, v123 = v141, true
                    end
                else
                    local v142 = v131.k94 - v119
                    if v123 then
                        table.insert(v120.k68, v128 - v122)
                    end
                    table.insert(v120.k92, v142 - v128)
                    table.insert(v120.k90, v140)
                    v120.k93 += 1
                    v120.k58 += 1
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
                v122, v123 = v131.k94 - v119, false
                v124 = v133
                v125, v126 = math.cos(v133), math.sin(v133)
                v130 = {}
            end
        end
    end
    v120.k91 = v121
    v120.k81 = v124
    if v121 == "move" then
        v120.k56 = v108 - v122
    elseif v121 == "low" then
        v120.k66 = v108 - v127
        v120.k56 = v108 - v128
        v120.k81 = v129
        if v120.k66 >= v68.k29 then
            v120.k91 = "stop"
        end
    else
        v120.k56 = v108 - v109
    end
    return v120
end

local function v143(v144)
    if v144 >= v68.k38 then
        return v68.k37
    end
    return v144 / (v144 + v68.k32)
end

local function v145(v146, v147, v148)
    local v149 = #v146
    if v149 > 0 and math.random() < v143(v149) then
        local v150 = math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
        return math.max(0.02, v146[math.random(1, v149)] * math.exp(v68.k15 * v150))
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

function v68.k47(v207, v208, v209, v210)
    local v211 = v207.k65
    local v212 = #v211
    if v212 == 0 then
        return nil
    end
    local v213 = v211[v212].k94
    local v214 = v211[v212].k75
    local v215, v216 = v68.k59(v207, v213, v68.k6)
    local v217 = v68.k99(v207, v213, 0.035).Y
    local v218 = math.abs(v217) > 6 or (not v207.k61 and v207.k60 ~= nil and v214.Y > v207.k60 + 0.5)
    local v219 = v68.k8
    local v220 = v207.k60
    local v221 = v209 and v68.k18 or v68.k11
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
    local v225 = math.max(0, v210 + v68.k14 + v68.k33)
    if v212 < 8 then
        local v226 = v225
        if v209 then
            v226 = v225 + (v214 - v208).Magnitude / v209
        end
        return Vector3.new(v214.X + v215 * v226, v222(v226), v214.Z + v216 * v226), v226, 1
    end
    local v227 = v68.k67(v207)
    local v228 = v227.k98
    local v229 = v68.k99(v207, v213, v68.k34)
    local v230 = v68.k99(v207, v213 - v68.k34, v68.k34)
    local v231, v232 = (v229.X - v230.X) / v68.k34, (v229.Z - v230.Z) / v68.k34
    local v233 = math.sqrt(v215 * v215 + v216 * v216)
    local v234 = v233 > 0.5 and (v231 * v215 + v232 * v216) / v233 or 0
    local v235 = math.atan2(v216, v215)
    local v236 = v233
    if v227.k91 == "move" then
        local v237, v238 = v229.X + v231 * v68.k1, v229.Z + v232 * v68.k1
        local v239 = math.sqrt(v237 * v237 + v238 * v238)
        if math.sqrt(v231 * v231 + v232 * v232) > v68.k2 and v239 > v227.k95 then
            v235 = math.atan2(v238, v237)
            if v233 < v228 * 0.85 and v239 > v233 then
                v236 = math.min(v239, v228)
            end
        end
        if v234 > v68.k2 and v233 < v228 * 0.85 then
            v236 = v228
        end
    end
    local v240 = (v227.k93 + v68.k36) / (v227.k93 + v227.k87 + v68.k36 + v68.k41)
    local v241
    if v227.k91 == "low" then
        local v242, v243 = v229.X + v231 * v68.k1, v229.Z + v232 * v68.k1
        local v244 = math.clamp((math.sqrt(v242 * v242 + v243 * v243) / v228 - 0.3) / 0.4, 0, 1)
        local v245 = v240 * (1 - 0.7 * v244)
        local v246 = (1 - v240) * (0.3 + 0.7 * v244)
        v240 = v245 / math.max(v245 + v246, 1e-6)
        if v244 > 0.5 then
            v241 = math.atan2(v243, v242)
        end
    end
    local v247 = (v227.k93 + v68.k36 * 0.5) / (v227.k58 + v68.k36 * 0.5 + v68.k41)
    local v248 = v227.k81 or v235
    local v249 = v68.k35
    local v250 = v209 and v225 + 1.6 or v225 + v249
    local v251 = {}
    local v252 = {}
    local v253 = v68.k3
    for v254 = 1, v68.k7 do
        local v255, v256 = v214.X, v214.Z
        local v257, v258 = v215, v216
        local v259, v260, v261, v262
        local v263
        local v264 = v248
        if v227.k91 == "move" then
            v259, v260, v261 = true, v235, v236
            v263 = v155(v227.k68, v68.k30, 0.25, v227.k56)
        elseif v227.k91 == "low" then
            if math.random() < v240 then
                v259 = false
                v263 = v155(v227.k92, v68.k31, 0.15, v227.k56)
            else
                local v265 = v151(v227.k97)
                if math.abs(v265) < 1.6 then
                    v265 = math.pi
                end
                v259, v260, v261 = true, v241 or v248 + v265, v228
                v264 = v260
                v263 = v145(v227.k68, v68.k30, 0.25)
            end
        else
            v259 = false
            v262 = v233 < v227.k95
            v263 = v155(v227.k92, v68.k31, 0.15, v227.k56)
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
                        v263 = v145(v227.k92, v68.k31, 0.15)
                    else
                        v260 += v151(v227.k97)
                        v263 = v145(v227.k68, v68.k30, 0.25)
                    end
                else
                    v259 = true
                    v262 = false
                    v260 = v264 + v151(v227.k90)
                    v261 = v228
                    v263 = v145(v227.k68, v68.k30, 0.25)
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
        v278, v279, v280 = v180(v251, v208, v68.k17)
    else
        v278, v279, v280 = v161(v251, v68.k10)
    end
    local v281 = v225
    if v209 then
        local v282, v283 = 0, 0
        for v284 = 1, #v251 do
            local v285, v286 = v251[v284][1] - v278, v251[v284][2] - v279
            if v285 * v285 + v286 * v286 <= v68.k17 ^ 2 then
                v282 += v252[v284]
                v283 += 1
            end
        end
        v281 = v283 > 0 and v282 / v283 or v225
    end
    return Vector3.new(v278, v222(v281), v279), v281, v280
end

function v68.k79(v287, v288, v289)
    if v287 then
        return v288 >= v68.k19 or v289 >= v68.k16
    end
    return v288 >= v68.k12 or v289 >= v68.k9
end

function v68.k69()
    local v290 = { k86 = {}, k88 = 0 }
    local v291 = 0
    local v292 = v68.k25
    while v292 <= v68.k24 + 1e-9 do
        v291 += 1
        local v293 = (v292 - v68.k26) / v68.k27
        v290.k86[v291] = -0.5 * v293 * v293
        v292 += v68.k28
    end
    return v290
end

function v68.k71(v294, v295, v296, v297, v298, v299, v300, v301)
    local v302 = v295.k65
    if #v302 < 2 then
        return false
    end
    local v303 = v302[#v302].k94
    local v304 = v299 - v298
    local v305, v306 = v304.X, v304.Z
    local v307 = math.sqrt(v305 * v305 + v306 * v306)
    if v307 < 0.5 then
        return false
    end
    v305, v306 = v305 / v307, v306 / v307
    local v308 = v68.k17 + 0.2
    local v309 = {}
    local v310 = 0
    local v311 = v68.k25
    while v311 <= v68.k24 + 1e-9 do
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
            local v316 = v68.k50(v295, v315)
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
        v311 += v68.k28
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
        v294.k86[v324] += math.log(v325)
    end
    v294.k88 += 1
    return true
end

function v68.k70(v326, v327, v328, v329, v330, v331, v332)
    local v333 = v327.k65
    if #v333 < 2 then
        return false
    end
    local v334 = v333[#v333].k94
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
    local v342 = v68.k25
    while v342 <= v68.k24 + 1e-9 do
        v341 += 1
        local v343 = v328 + v329 + v342
        local v344 = v68.k50(v327, v343)
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
        v342 += v68.k28
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
        v326.k86[v357] += math.log(v358)
    end
    v326.k88 += 1
    return true
end

function v68.k73(v359)
    if v359.k88 < v68.k21 then
        return nil
    end
    local v360, v361 = 1, -math.huge
    for v362, v363 in v359.k86 do
        if v363 > v361 then
            v360, v361 = v362, v363
        end
    end
    return v68.k25 + (v360 - 1) * v68.k28
end

function v68.k48(v364)
    local v365 = v68.k73(v364)
    if v365 then
        v68.k14 = math.clamp(v365 - v68.k33, v68.k25, v68.k24)
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
        v68.k8 = v7.Gravity
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
local v383 = { k63 = nil, k96 = nil, k82 = nil, k51 = nil }
local v384
local v385 = {}
local v386
local v387

local v388 = 3
local v389 = v9.__c44
if type(v389) ~= "table" or v9.__c45 ~= game.JobId or v9.__c46 ~= v388 then
    v389 = v68.k69()
    v9.__c44, v9.__c45, v9.__c46 = v389, game.JobId, v388
end
local function v390()
    v68.k48(v389)
end
v390()

local function v391(v392)
    return (v392 == "Gun" and v15.k13) or (v392 == "Knife" and v15.k20)
end

local function v393()
    local v394 = v8.Character
    local v395 = v394 and v394:FindFirstChildOfClass("Tool")
    if v395 == v383.k96 and (not v395 or v383.k82 and v383.k82.Parent) then
        return
    end
    v383.k96, v383.k63, v383.k82 = v395, nil, nil
    if v395 then
        if v28(v395) then
            local v396 = v395:FindFirstChild("Events")
            v383.k63 = "Knife"
            v383.k82 = v396 and v396:FindFirstChild("KnifeThrown")
        elseif v25(v395) then
            v383.k63 = "Gun"
            v383.k82 = v395:FindFirstChild("Shoot")
        end
    end
    local v397 = v394 and v394:FindFirstChild("HumanoidRootPart")
    v383.k51 = v397 and v397:FindFirstChild("GunRaycastAttachment")
end

local function v398(v399, v400)
    if typeof(v400) == "CFrame" then
        return v400.Position
    end
    if v399 == "Gun" and v383.k51 then
        return v383.k51.WorldPosition
    end
    local v401 = v383.k96 and v383.k96:FindFirstChild("Handle")
    return v401 and v401.Position
end

local function v402(v403, v404)
    for _, v405 in { "HumanoidRootPart", "Head", "UpperTorso", "Torso", "LowerTorso", "LeftUpperLeg", "RightUpperLeg" } do
        local v406 = v404:FindFirstChild(v405)
        if v406 then
            local v407 = v376(v7, v403, v406.Position - v403, v377)
            if not v407 then
                return true
            end
            if v407.Instance.Transparency >= 1 and v50(v403, v406.Position, v404) then
                return true
            end
        end
    end
    return false
end

local function v408(v409)
    table.clear(v385)
    local v410 = v41(v8)
    if not v410 then
        return nil
    end
    local v411 = v7.CurrentCamera
    local v412 = v65()
    local v413 = math.max(v411.ViewportSize.Magnitude, 1)
    local v414 = v8.Character:FindFirstChild("Head")
    local v415 = v398(v409) or (v414 and v414.Position) or v410.Position
    local v416, v417, v418, v419 = false, nil, nil, nil
    for _, v420 in v1:GetPlayers() do
        if v420 ~= v8 then
            local v421, _, v422 = v41(v420)
            local v423, v424 = v35(v420)
            if v421 and not v424 then
                if v423 == "Murderer" then
                    v416 = true
                end
                if v402(v415, v422) then
                    local v425, v426 = v411:WorldToViewportPoint(v421.Position)
                    local v427 = (v421.Position - v410.Position).Magnitude
                    local v428
                    if v426 and v425.Z > 0 then
                        v428 = (Vector2.new(v425.X, v425.Y) - v412).Magnitude
                    else
                        v428 = v413 + v427
                    end
                    local v429 = v423 == "Sheriff" or v423 == "Hero"
                    local v430 = { k76 = v420, k83 = v421, k53 = v422, k72 = math.clamp(v428 / v413, 0, 2), k77 = v429 }
                    if v423 == "Murderer" then
                        v417 = v430
                    end
                    table.insert(v385, v430)
                    local v431 = v428 + v427 * 3
                    if v409 == "Knife" and v429 then
                        v431 -= 120
                    end
                    if v384 and v384.k76 == v420 then
                        v431 -= 40
                    end
                    if not v419 or v431 < v419 then
                        v418, v419 = v430, v431
                    end
                end
            end
        end
    end
    if v409 == "Gun" and v416 then
        table.clear(v385)
        if v417 then
            table.insert(v385, v417)
        end
        return v417
    end
    return v418
end

local function v432(v433, v434)
    local v435 = v376(v7, v433, v434 - v433, v377)
    return not v435 or v435.Instance.Transparency >= 1
end

local function v436(v437, v438, v439)
    if not v437 or not v437.k83.Parent then
        return nil
    end
    local v440 = v382[v437.k76]
    if not v440 or v440.k83 ~= v437.k83 or #v440.k65 < 2 then
        return nil
    end
    local v441, _, v442 = v68.k47(v440, v439, v438 == "Knife" and v366 or nil, v369)
    if not v441 then
        return nil
    end
    local v443 = v440.k65[#v440.k65].k75
    local v444 = v441 - v443
    if v444.Magnitude > 0.5 then
        local v445 = v376(v7, v443, v444, v377)
        if v445 and v445.Instance.CanCollide then
            v441 = v445.Position - v444.Unit * 1.5
        end
    end
    if not v432(v439, v441) then
        local v446 = v441 - v439
        local v447 = Vector3.new(-v446.Z, 0, v446.X)
        v447 = v447.Magnitude > 0.01 and v447.Unit or Vector3.new(1, 0, 0)
        for _, v448 in {
            Vector3.new(0, 0.8, 0), Vector3.new(0, 1.6, 0), Vector3.new(0, -1.0, 0), Vector3.new(0, -2.0, 0),
            v447 * 0.7, -v447 * 0.7, v447 * 0.6 + Vector3.new(0, 0.8, 0), -v447 * 0.6 + Vector3.new(0, 0.8, 0),
            v447 * 0.6 - Vector3.new(0, 1.0, 0), -v447 * 0.6 - Vector3.new(0, 1.0, 0),
        } do
            local v449 = v441 + v448
            if v432(v439, v449) then
                v441 = v449
                break
            end
        end
    end
    return v441, v442
end

local function v450(v451, v452)
    if v451 == "Knife" and #v385 > 1 then
        local v453, v454, v455, v456
        for _, v457 in v385 do
            local v458, v459 = v436(v457, v451, v452)
            if v458 then
                local v460 = v459 - 0.05 * v457.k72 + (v457.k77 and 0.08 or 0)
                if not v456 or v460 > v456 then
                    v453, v454, v455, v456 = v457, v458, v459, v460
                end
            end
        end
        if v453 then
            return v454, v455, v453
        end
    end
    local v461, v462 = v436(v384, v451, v452)
    return v461, v462, v384
end

local function v463(v464, v465, v466)
    if v464 == "Gun" then
        local v467 = v466 - v465
        if v467.Magnitude > 0.1 then
            return CFrame.new(v466 + v467.Unit * 4)
        end
    end
    return CFrame.new(v466)
end

local function v468(v469, v470)
    local v471 = v469.FireServer
    return v471(v469, table.unpack(v470, 1, v470.n))
end

local function v472(v473, v474, v475, v476)
    local v477 = v474 and v382[v474.k76]
    if not v477 then
        return
    end
    local v478 = { k63 = v473, k94 = os.clock(), k84 = v369, k74 = v475, k47 = v476, k80 = v477, k53 = v474.k53, k96 = v383.k96 }
    if v473 == "Gun" then
        v387 = v478
        return
    end
    task.delay(1.9, function()
        if v10 then
            return
        end
        local v479 = v477.k55
        local v480 = v479 ~= nil and v479 >= v478.k94 and v479 <= v478.k94 + 1.7
        if v68.k71(v389, v477, v478.k94, v478.k84, v478.k74, v478.k47, v366, v480) then
            v390()
        end
    end)
end

local function v481(v482, v483, v484, v485)
    local v486 = v387
    if not v486 or v482 ~= v486.k96 or typeof(v484) ~= "Vector3" or os.clock() - v486.k94 > 1.5 then
        return
    end
    v387 = nil
    local v487 = v486.k74
    if typeof(v483) == "Vector3" then
        v487 = v483
    elseif typeof(v483) == "Instance" then
        if v483:IsA("Attachment") then
            v487 = v483.WorldPosition
        elseif v483:IsA("BasePart") then
            v487 = v483.Position
        end
    end
    local v488 = typeof(v485) == "Instance" and v486.k53 ~= nil and v485:IsDescendantOf(v486.k53)
    task.delay(1.1, function()
        if v10 then
            return
        end
        if v68.k70(v389, v486.k80, v486.k94, v486.k84, v487, v484, v488) then
            v390()
        end
    end)
end
task.spawn(function()
    local v489 = v3:WaitForChild("ClientServices", 10)
    local v490 = v489 and v489:WaitForChild("WeaponService", 10)
    local v491 = v490 and v490:WaitForChild("GunFired", 10)
    if v491 and not v10 then
        v12(v491.OnClientEvent:Connect(function(...)
            pcall(v481, ...)
        end))
    end
end)

local function v492(v493)
    v386 = nil
    local v494 = v493.k49
    if v493.k63 == "Gun" and v383.k51 and typeof(v494[1]) == "CFrame" then
        v494[1] = v383.k51.WorldCFrame
    end
    local v495 = v398(v493.k63, v494[1]) or v493.k74
    local v496, _, v497 = v450(v493.k63, v495)
    if v496 then
        v494[2] = v463(v493.k63, v495, v496)
    elseif v493.k47 then
        v494[2] = v493.k47
    end
    if pcall(v468, v493.k82, v494) and typeof(v494[2]) == "CFrame" then
        v472(v493.k63, v497 or v493.k57, v495, v494[2].Position)
    end
end

local v498 = 0
v12(v2.PreSimulation:Connect(function()
    if v10 then
        return
    end
    if not (v15.k13 or v15.k20) then
        if next(v382) then
            table.clear(v382)
        end
        v384 = nil
        table.clear(v385)
        if v386 then
            v492(v386)
        end
        return
    end
    local v499 = os.clock()
    for _, v500 in v1:GetPlayers() do
        if v500 ~= v8 then
            local v501 = v500.Character
            local v502 = v501 and v501:FindFirstChild("HumanoidRootPart")
            local v503 = v501 and v501:FindFirstChildOfClass("Humanoid")
            if v502 and v503 then
                local v504 = v382[v500]
                if not v504 or v504.k83 ~= v502 then
                    v504 = v68.new()
                    v504.k83 = v502
                    v382[v500] = v504
                end
                if v503.Health <= 0 then
                    v504.k55 = v504.k55 or v499
                end
                if not v504.k55 or v499 - v504.k55 < 0.6 then
                    local v505 = v503:GetState()
                    local v506 = v503.FloorMaterial ~= Enum.Material.Air
                        or (v505 ~= Enum.HumanoidStateType.Freefall and v505 ~= Enum.HumanoidStateType.Jumping)
                    v68.k78(v504, v499, v502.Position, v506)
                end
            else
                v382[v500] = nil
            end
        end
    end
    v498 += 1
    if v498 % 60 == 0 then
        v378()
    end
    v393()
    if v383.k63 and v391(v383.k63) then
        v384 = v408(v383.k63)
    else
        v384 = nil
        table.clear(v385)
    end
    local v507 = v386
    if v507 then
        if v507.k82 ~= v383.k82 or not v384 then
            v492(v507)
        else
            local v508 = v398(v507.k63, v383.k51 and v383.k51.WorldCFrame) or v507.k74
            local _, v509 = v450(v507.k63, v508)
            if not v509 or v68.k79(v507.k63 == "Knife", v509, v499 - v507.k89) then
                v492(v507)
            end
        end
    end
end))
v12(v1.PlayerRemoving:Connect(function(v510)
    v382[v510] = nil
end))

local function v511(v512, v513)
    local v514 = v383.k63
    local v515 = v398(v514, v513[1])
    if not v515 then
        return false
    end
    local v516, v517, v518 = v450(v514, v515)
    if not v516 then
        return false
    end
    local v519 = v463(v514, v515, v516)
    if not v68.k79(v514 == "Knife", v517, 0) then
        if v386 then
            v492(v386)
        end
        v386 = { k82 = v512, k49 = v513, k63 = v514, k74 = v515, k47 = v519, k57 = v518, k89 = os.clock() }
        return true
    end
    v513[2] = v519
    v468(v512, v513)
    v472(v514, v518, v515, v519.Position)
    return true
end

local v520 = false
if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local v521
    local v522 = typeof(checkcaller) == "function" and checkcaller or function()
        return false
    end
    local function v523(self, ...)
        if v10 or self ~= v383.k82 then
            return v521(self, ...)
        end
        if getnamecallmethod() ~= "FireServer" or v522() or not v391(v383.k63) then
            return v521(self, ...)
        end
        local v524 = table.pack(...)
        local v525, v526 = pcall(v511, self, table.pack(...))
        if v525 and v526 then
            return nil
        end
        return v468(self, v524)
    end
    if typeof(newcclosure) == "function" then
        v523 = newcclosure(v523)
    end
    v521 = hookmetamethod(game, "__namecall", v523)
    v520 = true
end

local v527
pcall(function()
    v527 = require(v3:WaitForChild("ClientServices", 5):WaitForChild("WeaponService", 5))
end)
local v528, v529
if not v520 and type(v527) == "table" then
    v528, v529 = v527.GetMouseTargetCFrame, v527.GetTargetPosition
    local function v530()
        local v531 = v383.k63
        if v10 or not v531 or not v391(v531) then
            return nil
        end
        local v532 = v398(v531)
        local v533 = v532 and v450(v531, v532)
        return v533 and v463(v531, v532, v533)
    end
    v527.GetMouseTargetCFrame = function(self, ...)
        local v534, v535 = pcall(v530)
        if v534 and v535 then
            return v535
        end
        return v528(self, ...)
    end
    v527.GetTargetPosition = function(self, v536, v537, ...)
        v58, v59 = Vector2.new(v536, v537), os.clock()
        local v538, v539 = pcall(v530)
        if v538 and v539 then
            return v539
        end
        return v529(self, v536, v537, ...)
    end
end

local v540 = Instance.new("Folder")
v540.Name = "\0"
v540.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
local v541 = {}
local v542 = {
    Murderer = Color3.fromRGB(255, 50, 50),
    Sheriff = Color3.fromRGB(50, 140, 255),
    Hero = Color3.fromRGB(50, 140, 255),
    Innocent = Color3.fromRGB(60, 230, 90),
}
local function v543(v544)
    local v545 = v541[v544]
    if v545 then
        v545.k62:Destroy()
        v545.k52:Destroy()
        v541[v544] = nil
    end
end
v12(v1.PlayerRemoving:Connect(v543))
local function v546()
    for _, v547 in v1:GetPlayers() do
        if v547 ~= v8 then
            local v548, _, v549 = v41(v547)
            local v550, v551 = v35(v547)
            if v15.k5 and v548 and not v551 then
                local v552 = v542[v550] or v542.Innocent
                local v553 = v541[v547]
                if not v553 or v553.k53 ~= v549 then
                    v543(v547)
                    local v554 = Instance.new("Highlight")
                    v554.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    v554.FillTransparency = 0.55
                    v554.OutlineTransparency = 0
                    v554.Adornee = v549
                    v554.Parent = v540
                    local v555 = Instance.new("BillboardGui")
                    v555.AlwaysOnTop = true
                    v555.Size = UDim2.fromOffset(160, 22)
                    v555.StudsOffset = Vector3.new(0, 3.4, 0)
                    v555.Adornee = v548
                    v555.Parent = v540
                    local v556 = Instance.new("TextLabel")
                    v556.BackgroundTransparency = 1
                    v556.Size = UDim2.fromScale(1, 1)
                    v556.Font = Enum.Font.GothamBold
                    v556.TextSize = 13
                    v556.TextStrokeTransparency = 0.4
                    v556.Text = v547.DisplayName
                    v556.Parent = v555
                    v553 = { k62 = v554, k52 = v555, k64 = v556, k53 = v549 }
                    v541[v547] = v553
                end
                if v553.k54 ~= v552 then
                    v553.k54 = v552
                    v553.k62.FillColor = v552
                    v553.k62.OutlineColor = v552
                    v553.k64.TextColor3 = v552
                end
            else
                v543(v547)
            end
        end
    end
end
task.spawn(function()
    while not v10 do
        pcall(v546)
        task.wait(0.25)
    end
end)

local v557 = {}
local v558 = {}
local v559
local function v560(v561)
    local v562 = v558[v561]
    if v562 then
        return v562
    end
    local v563 = {}
    for _, v564 in v561:GetDescendants() do
        if v564:IsA("BasePart") then
            table.insert(v563, v564)
        end
    end
    v558[v561] = v563
    local v565
    v565 = v561.DescendantAdded:Connect(function(v566)
        if v566:IsA("BasePart") then
            table.insert(v563, v566)
        end
    end)
    v561.AncestryChanged:Once(function()
        v558[v561] = nil
        v565:Disconnect()
    end)
    return v563
end
v12(v2.PreSimulation:Connect(function()
    if not v15.k4 then
        v559 = nil
        return
    end
    local v567, v568 = v41(v8)
    local v569 = os.clock()
    for _, v570 in v1:GetPlayers() do
        if v570 ~= v8 then
            local v571 = v570.Character
            local v572 = v571 and v571:FindFirstChild("HumanoidRootPart")
            if v572 and v567 then
                local v573 = v572.Position - v567.Position
                if v573.X * v573.X + v573.Y * v573.Y + v573.Z * v573.Z < 3600 then
                    local v574 = v572.AssemblyAngularVelocity
                    local v575 = v572.AssemblyLinearVelocity
                    if v574:Dot(v574) > 625 or v575:Dot(v575) > 14400 then
                        v557[v570] = v569 + 3
                    end
                end
            end
            local v576 = v557[v570]
            if v576 then
                if v569 > v576 or not v571 then
                    v557[v570] = nil
                else
                    for _, v577 in v560(v571) do
                        if v577.CanCollide then
                            v577.CanCollide = false
                        end
                    end
                end
            end
        end
    end
    if not v567 then
        v559 = nil
        return
    end
    local v578 = v567.AssemblyLinearVelocity
    local v579 = math.sqrt(v578.X * v578.X + v578.Z * v578.Z)
    local v580 = v567.AssemblyAngularVelocity.Magnitude
    local v581 = v568.WalkSpeed
    if (v579 > math.max(v581 * 5, 90) or v578.Y > 140 or v580 > 35) and v559 then
        v567.AssemblyLinearVelocity = Vector3.zero
        v567.AssemblyAngularVelocity = Vector3.zero
        v567.CFrame = v559
    elseif v579 < v581 * 2 + 4 and v580 < 8 and math.abs(v578.Y) < 60 then
        v559 = v567.CFrame
    end
end))

local v582 = v14:CreateWindow({
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

local v583 = "\u{200B}\u{200C}\u{200B}"
pcall(function()
    v582:EditOpenButton({
        Title = v583,
        Icon = "",
        Transparency = 1,
        StrokeThickness = 0,
    })
end)
local v584 = {}
local function v585()
    local v586 = { game:GetService("CoreGui") }
    if typeof(gethui) == "function" then
        table.insert(v586, gethui())
    end
    local v587 = v8:FindFirstChildOfClass("PlayerGui")
    if v587 then
        table.insert(v586, v587)
    end
    local v588 = false
    for _, v589 in v586 do
        local v590, v591 = pcall(v589.GetDescendants, v589)
        if v590 then
            for _, v592 in v591 do
                if (v592:IsA("TextLabel") or v592:IsA("TextButton")) and v592.Text == v583 then
                    local v593 = v592
                    local v594 = v592.Parent
                    while v594 and v594:IsA("GuiObject") and v594.AbsoluteSize.X * v594.AbsoluteSize.Y < 320 * 160 do
                        v593 = v594
                        v594 = v594.Parent
                    end
                    if v593:IsA("GuiObject") and not v584[v593] then
                        v584[v593] = true
                        v593.Visible = false
                        v12(v593:GetPropertyChangedSignal("Visible"):Connect(function()
                            if v593.Visible then
                                v593.Visible = false
                            end
                        end))
                    end
                    v588 = true
                end
            end
        end
    end
    return v588
end
task.spawn(function()
    for _, v595 in { 0.2, 0.5, 1, 2, 4, 8 } do
        task.wait(v595)
        if v10 then
            return
        end
        local v596, v597 = pcall(v585)
        if v596 and v597 then
            return
        end
    end
end)
local v598 = Enum.KeyCode.K
v12(v4.InputBegan:Connect(function(v599)
    if v599.KeyCode == v598 then
        task.delay(0.15, pcall, v585)
        task.delay(0.6, pcall, v585)
    end
end))

local v600 = v582:Tab({ Title = "Main", Icon = "crosshair" })
v600:Section({ Title = "Silent Aim" })
v600:Toggle({
    Title = "Gun Silent Aim",
    Default = false,
    Callback = function(v601)
        v15.k13 = v601
    end,
})
v600:Toggle({
    Title = "Murderer Silent Aim",
    Default = false,
    Callback = function(v602)
        v15.k20 = v602
    end,
})
v600:Section({ Title = "Other" })
v600:Toggle({
    Title = "ESP",
    Default = false,
    Callback = function(v603)
        v15.k5 = v603
    end,
})
v600:Toggle({
    Title = "Anti Fling",
    Default = false,
    Callback = function(v604)
        v15.k4 = v604
        if not v604 then
            table.clear(v557)
        end
    end,
})

local v605 = v582:Tab({ Title = "Settings", Icon = "settings" })
local v606 = v605:Keybind({
    Title = "Toggle UI",
    Callback = function(v607)
        local v608 = typeof(v607) == "EnumItem" and v607 or Enum.KeyCode[tostring(v607)]
        if v608 then
            v598 = v608
            pcall(v582.SetToggleKey, v582, v608)
        end
    end,
})
pcall(function()
    v606:SetValue("K")
end)

v9.__c43 = function()
    v10 = true
    if v386 then
        pcall(v492, v386)
    end
    for _, v609 in v11 do
        pcall(v609.Disconnect, v609)
    end
    for v610 in v541 do
        v543(v610)
    end
    v540:Destroy()
    if v528 and v527 then
        v527.GetMouseTargetCFrame = v528
        v527.GetTargetPosition = v529
    end
    pcall(v582.Close, v582)
end
