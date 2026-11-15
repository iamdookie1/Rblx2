local v1 = game:GetService("Players")
local v2 = game:GetService("RunService")
local v3 = game:GetService("ReplicatedStorage")
local v4 = game:GetService("UserInputService")
local v5 = game:GetService("CollectionService")
local v6 = game:GetService("Stats")
local v7 = workspace
local v8 = v1.LocalPlayer

local v9 = (typeof(getgenv) == "function" and getgenv()) or _G
if v9.__c46 then
    pcall(v9.__c46)
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
    k21 = false,
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
    k45 = 3.0,
    k37 = 0.034,
    k6 = 0.067,
    k8 = 196.2,
    k14 = 0.06,
    k35 = 0.01,
    k7 = 80,
    k38 = 1 / 30,
    k25 = 2.0,
    k24 = 0.4,
    k42 = 0.7,
    k23 = 0.1,
    k31 = 0.12,
    k32 = 1.5,
    k33 = 0.8,
    k34 = 1.5,
    k39 = 0.5,
    k44 = 0.7,
    k41 = 3,
    k40 = 0.9,
    k15 = 0.2,
    k1 = 0.05,
    k2 = 40,
    k43 = 0.035,
    k3 = 0.05,
    k10 = 1.0,
    k16 = 3,
    k36 = 0.2,
    k18 = 1.2,
    k9 = 0.5,
    k12 = 0.95,
    k17 = 0.35,
    k20 = 0.75,
    k11 = 0.3,
    k19 = -0.5,
    k27 = -0.3,
    k26 = 0.4,
    k30 = 0.005,
    k28 = 0.07,
    k29 = 0.12,
    k22 = 2,
}

function v68.new()
    return { k73 = {}, k64 = nil, k65 = true, k104 = {}, k71 = {}, k67 = 50 }
end

function v68.k86(v69, v70, v71, v72)
    local v73 = v69.k73
    local v74 = #v73
    if v74 > 0 and v70 <= v73[v74].k103 then
        return
    end
    v73[v74 + 1] = { k103 = v70, k83 = v71 }
    v74 += 1
    if v72 then
        v69.k64 = v71.Y
    end
    if v69.k65 and not v72 then
        local v75 = v69.k70 ~= nil and v70 - v69.k70 < 0.2
        table.insert(v69.k104, { k103 = v70, k88 = v75 })
    elseif v72 and not v69.k65 then
        v69.k70 = v70
        table.insert(v69.k71, v70)
    end
    local v76 = v70 - v68.k16
    while v69.k104[1] and v69.k104[1].k103 < v76 do
        table.remove(v69.k104, 1)
    end
    while v69.k71[1] and v69.k71[1] < v76 do
        table.remove(v69.k71, 1)
    end
    v69.k65 = v72
    local v77 = v70 - v68.k45 - 0.2
    local v78 = 0
    while v78 < v74 - 2 and v73[v78 + 1].k103 < v77 do
        v78 += 1
    end
    if v78 > 0 then
        table.move(v73, v78 + 1, v74, 1)
        for v79 = v74 - v78 + 1, v74 do
            v73[v79] = nil
        end
    end
end

function v68.k54(v80, v81)
    local v82 = v80.k73
    local v83 = #v82
    if v81 >= v82[v83].k103 then
        return v82[v83].k83
    end
    if v81 <= v82[1].k103 then
        return v82[1].k83
    end
    local v84, v85 = 1, v83
    while v85 - v84 > 1 do
        local v86 = (v84 + v85) // 2
        if v82[v86].k103 <= v81 then
            v84 = v86
        else
            v85 = v86
        end
    end
    local v87, v88 = v82[v84], v82[v85]
    return v87.k83 + (v88.k83 - v87.k83) * ((v81 - v87.k103) / math.max(v88.k103 - v87.k103, 1e-6))
end

function v68.k109(v89, v90, v91)
    return (v68.k54(v89, v90) - v68.k54(v89, v90 - v91)) / v91
end

local function v92(v93)
    v93 = (v93 + math.pi) % (2 * math.pi)
    return v93 - math.pi
end

function v68.k63(v94, v95, v96)
    local v97, v98, v99, v100, v101, v102, v103 = 0, 0, 0, 0, 0, 0, 0
    for v104 = 0, 4 do
        local v105 = -v96 * v104 / 4
        local v106 = v68.k54(v94, v95 + v105)
        v97 += 1
        v98 += v105
        v99 += v106.X
        v100 += v106.Z
        v101 += v105 * v105
        v102 += v105 * v106.X
        v103 += v105 * v106.Z
    end
    local v107 = v97 * v101 - v98 * v98
    if v107 <= 1e-9 then
        return 0, 0
    end
    return (v97 * v102 - v98 * v99) / v107, (v97 * v103 - v98 * v100) / v107
end

function v68.k75(v108)
    local v109 = v108.k73
    local v110 = v109[#v109].k103
    local v111 = math.max(v109[1].k103 + v68.k37, v110 - v68.k45)
    local v112 = {}
    local v113 = v111
    while v113 <= v110 + 1e-6 do
        local v114 = v68.k109(v108, v113, v68.k37)
        v112[#v112 + 1] = { k103 = v113, k110 = v114.X, k111 = v114.Z, k94 = math.sqrt(v114.X * v114.X + v114.Z * v114.Z) }
        v113 += 1 / 60
    end
    local v115 = {}
    for _, v116 in v112 do
        if v116.k94 > v68.k25 then
            v115[#v115 + 1] = v116.k94
        end
    end
    table.sort(v115)
    local v117 = #v115 >= 6 and v115[math.max(1, math.floor(#v115 * 0.7))] or 16
    local v118 = math.max(v68.k25, v117 * v68.k24)
    local v119 = v68.k3
    local v120 = v119 * math.log(1 / v68.k24) + v68.k37 / 2
    local v121 = v119 * math.log(1 / (1 - v68.k24)) + v68.k37 / 2
    local v122 = {
        k76 = {}, k101 = {}, k107 = {}, k99 = {},
        k102 = 0, k96 = 0, k62 = 0,
        k108 = v117, k105 = v118,
    }
    local v123, v124, v125, v126, v127, v128
    local v129, v130, v131
    local v132 = {}
    local v133
    for _, v134 in v112 do
        local v135 = v134.k94 > v118
        local v136 = v135 and math.atan2(v134.k111, v134.k110) or nil
        if not v123 then
            v123 = v135 and "move" or "stop"
            v124, v125 = v134.k103, false
            if v135 then
                v126 = v136
                v127, v128 = math.cos(v136), math.sin(v136)
            end
        elseif v123 == "move" then
            if v135 then
                table.insert(v132, v134)
                local v137 = v92(v136 - v126)
                if math.abs(v137) > v68.k42 then
                    local v138 = math.abs(v137) / 2
                    local v139 = v134.k103
                    for _, v140 in v132 do
                        local v141 = v140.k110 * v127 + v140.k111 * v128
                        local v142 = math.abs(v140.k110 * v128 - v140.k111 * v127)
                        if math.atan2(v142, v141) >= v138 then
                            v139 = v140.k103
                            break
                        end
                    end
                    v139 -= v68.k43 + v68.k37 / 2
                    local v143 = v122.k107[#v122.k107]
                    if v133 and v143 and v139 - v133 < v68.k23 and (v143 > 0) == (v137 > 0) and math.abs(v143 + v137) <= math.pi + 0.3 then
                        if math.abs(v143) <= 1.6 and math.abs(v143 + v137) > 1.6 then
                            v122.k96 += 1
                        end
                        v122.k107[#v122.k107] = v143 + v137
                    else
                        if v125 then
                            table.insert(v122.k76, v139 - v124)
                        end
                        table.insert(v122.k107, v137)
                        v122.k62 += 1
                        if math.abs(v137) > 1.6 then
                            v122.k96 += 1
                        end
                        v124, v125 = v139, true
                    end
                    v133 = v139
                    v126 = v136
                    v127, v128 = math.cos(v136), math.sin(v136)
                    v132 = {}
                end
            else
                v123 = "low"
                v129 = v134.k103
                v130 = v134.k103 - v120
                v131 = v126
            end
        elseif v123 == "low" then
            if v135 then
                local v144 = v92(v136 - v131)
                if v134.k103 - v129 < v68.k31 then
                    if math.abs(v144) > v68.k42 then
                        local v145 = (v130 + v134.k103 - v121) / 2
                        if v125 then
                            table.insert(v122.k76, v145 - v124)
                        end
                        table.insert(v122.k107, v144)
                        v122.k62 += 1
                        if math.abs(v144) > 1.6 then
                            v122.k96 += 1
                        end
                        v124, v125 = v145, true
                    end
                else
                    local v146 = v134.k103 - v121
                    if v125 then
                        table.insert(v122.k76, v130 - v124)
                    end
                    table.insert(v122.k101, v146 - v130)
                    table.insert(v122.k99, v144)
                    v122.k102 += 1
                    v122.k62 += 1
                    v124, v125 = v146, true
                end
                v123 = "move"
                v126 = v136
                v127, v128 = math.cos(v136), math.sin(v136)
                v132 = {}
            end
        else
            if v135 then
                v123 = "move"
                v124, v125 = v134.k103 - v121, false
                v126 = v136
                v127, v128 = math.cos(v136), math.sin(v136)
                v132 = {}
            end
        end
    end
    local v147, v148 = 0, 0
    for v149 = 2, #v122.k107 do
        local v150, v151 = v122.k107[v149 - 1], v122.k107[v149]
        if math.abs(v150) < 2.8 and math.abs(v151) < 2.8 then
            if (v150 > 0) == (v151 > 0) then
                v147 += 1
            else
                v148 += 1
            end
        end
    end
    v122.k51 = (v148 + 1) / (v148 + v147 + 2)
    local v152 = v122.k107[#v122.k107]
    v122.k72 = v152 and (v152 > 0 and 1 or -1) or nil
    v122.k100 = v123
    v122.k90 = v126
    if v123 == "move" then
        v122.k60 = v110 - v124
    elseif v123 == "low" then
        v122.k74 = v110 - v129
        v122.k60 = v110 - v130
        v122.k90 = v131
        if v122.k74 >= v68.k31 then
            v122.k100 = "stop"
        end
    else
        v122.k60 = v110 - v111
    end
    return v122
end

local function v153(v154)
    if v154 >= v68.k41 then
        return v68.k40
    end
    return v154 / (v154 + v68.k34)
end

local function v155(v156, v157, v158)
    local v159 = #v156
    if v159 > 0 and math.random() < v153(v159) then
        local v160 = math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
        return math.max(0.02, v156[math.random(1, v159)] * math.exp(v68.k15 * v160))
    end
    return v158 - v157 * math.log(1 - math.random())
end

local function v161(v162)
    local v163 = #v162
    if v163 > 0 and math.random() < v153(v163) then
        local v164 = v162[math.random(1, v163)]
        return math.random() < 0.5 and v164 or -v164
    end
    return (math.random() * 2 - 1) * math.pi
end

local function v165(v166, v167, v168, v169)
    for _ = 1, 24 do
        local v170 = v155(v166, v167, v168)
        if v170 > v169 then
            return v170 - v169
        end
    end
    return -v167 * math.log(1 - math.random()) * 0.5
end

local function v171(v172, v173)
    local v174 = v173 * v173
    local v175, v176 = 1, -1
    for v177, v178 in v172 do
        local v179 = 0
        for _, v180 in v172 do
            local v181, v182 = v178[1] - v180[1], v178[2] - v180[2]
            if v181 * v181 + v182 * v182 <= v174 then
                v179 += 1
            end
        end
        if v179 > v176 then
            v175, v176 = v177, v179
        end
    end
    local v183 = v172[v175]
    local v184, v185, v186 = 0, 0, 0
    for _, v187 in v172 do
        local v188, v189 = v183[1] - v187[1], v183[2] - v187[2]
        if v188 * v188 + v189 * v189 <= v174 then
            v184 += v187[1]
            v185 += v187[2]
            v186 += 1
        end
    end
    return v184 / v186, v185 / v186, v176 / #v172
end

local function v190(v191, v192, v193)
    local v194 = #v191
    local v195, v196, v197 = {}, {}, {}
    for v198, v199 in v191 do
        local v200, v201 = v199[1] - v192.X, v199[2] - v192.Z
        local v202 = math.max(math.sqrt(v200 * v200 + v201 * v201), v193 * 1.01)
        v195[v198] = math.atan2(v201, v200)
        v196[v198] = math.asin(v193 / v202)
        v197[v198] = v202
    end
    local v203, v204 = v195[1], -1
    for v205 = 1, v194 do
        local v206 = 0
        local v207 = v195[v205]
        for v208 = 1, v194 do
            if math.abs(v92(v207 - v195[v208])) <= v196[v208] then
                v206 += 1
            end
        end
        if v206 > v204 then
            v203, v204 = v207, v206
        end
    end
    local v209, v210 = -math.huge, math.huge
    local v211, v212 = 0, 0
    for v213 = 1, v194 do
        local v214 = v92(v195[v213] - v203)
        if math.abs(v214) <= v196[v213] then
            v209 = math.max(v209, v214 - v196[v213])
            v210 = math.min(v210, v214 + v196[v213])
            v211 += v197[v213]
            v212 += 1
        end
    end
    local v215 = v203
    if v209 <= v210 then
        v215 = v203 + (v209 + v210) / 2
    end
    local v216 = v211 / math.max(v212, 1)
    return v192.X + math.cos(v215) * v216, v192.Z + math.sin(v215) * v216, v204 / v194
end

function v68.k50(v217, v218, v219, v220)
    local v221 = v217.k73
    local v222 = #v221
    if v222 == 0 then
        return nil
    end
    local v223 = v221[v222].k103
    local v224 = v221[v222].k83
    local v225, v226 = v68.k63(v217, v223, v68.k6)
    local v227 = v68.k109(v217, v223, 0.035).Y
    local v228 = math.abs(v227) > 6 or (not v217.k65 and v217.k64 ~= nil and v224.Y > v217.k64 + 0.5)
    local v229 = v68.k8
    local v230 = v217.k64
    local v231 = v219 and v68.k19 or v68.k11
    local function v232(v233)
        if not v228 then
            return v224.Y + v231
        end
        local v234 = v224.Y + v227 * v233 - 0.5 * v229 * v233 * v233
        if v230 and v234 < v230 then
            v234 = v230
        end
        return v234 + v231 * 0.5
    end
    local v235 = math.max(0, v220 + v68.k14 + v68.k35)
    if v222 < 8 then
        local v236 = v235
        if v219 then
            v236 = v235 + (v224 - v218).Magnitude / v219
        end
        return Vector3.new(v224.X + v225 * v236, v232(v236), v224.Z + v226 * v236), v236, 1
    end
    local v237 = v68.k75(v217)
    local v238 = v237.k108
    local v239 = v68.k109(v217, v223, v68.k37)
    local v240 = v68.k109(v217, v223 - v68.k37, v68.k37)
    local v241, v242 = (v239.X - v240.X) / v68.k37, (v239.Z - v240.Z) / v68.k37
    local v243 = math.sqrt(v225 * v225 + v226 * v226)
    local v244 = v243 > 0.5 and (v241 * v225 + v242 * v226) / v243 or 0
    local v245 = math.atan2(v226, v225)
    local v246 = v243
    if v237.k100 == "move" then
        local v247, v248 = v239.X + v241 * v68.k1, v239.Z + v242 * v68.k1
        local v249 = math.sqrt(v247 * v247 + v248 * v248)
        if math.sqrt(v241 * v241 + v242 * v242) > v68.k2 and v249 > v237.k105 then
            v245 = math.atan2(v248, v247)
            if v243 < v238 * 0.85 and v249 > v243 then
                v246 = math.min(v249, v238)
            end
        end
        if v244 > v68.k2 and v243 < v238 * 0.85 then
            v246 = v238
        end
    end
    local v250 = (v237.k102 + v68.k39) / (v237.k102 + v237.k96 + v68.k39 + v68.k44)
    local v251
    if v237.k100 == "low" then
        local v252, v253 = v239.X + v241 * v68.k1, v239.Z + v242 * v68.k1
        local v254 = math.clamp((math.sqrt(v252 * v252 + v253 * v253) / v238 - 0.3) / 0.4, 0, 1)
        local v255 = v250 * (1 - 0.7 * v254)
        local v256 = (1 - v250) * (0.3 + 0.7 * v254)
        v250 = v255 / math.max(v255 + v256, 1e-6)
        if v254 > 0.5 then
            v251 = math.atan2(v253, v252)
        end
    end
    local v257 = (v237.k102 + v68.k39 * 0.5) / (v237.k62 + v68.k39 * 0.5 + v68.k44)
    local v258 = v237.k90 or v245
    local v259 = math.min(v68.k16, v223 - v221[1].k103)
    local v260, v261 = 0, 0
    for _, v262 in v217.k104 do
        if v262.k103 + 0.06 <= v223 and v68.k109(v217, v262.k103 + 0.06, 0.05).Y > 8 then
            v260 += 1
            if v262.k88 then
                v261 += 1
            end
        end
    end
    local v263 = v259 > 0.5 and v260 / v259 or 0
    local v264 = math.clamp((v261 + v68.k36) / (#v217.k71 + 1), 0, 0.95)
    local v265 = v217.k67 or 50
    local v266 = v230 or (v228 and -math.huge or v224.Y)
    local v267 = v68.k38
    local v268 = v219 and v235 + 1.6 or v235 + v267
    local v269 = {}
    local v270 = {}
    local v271 = v68.k3
    for v272 = 1, v68.k7 do
        local v273, v274 = v224.X, v224.Z
        local v275, v276 = v225, v226
        local v277, v278, v279, v280
        local v281
        local v282 = v258
        if v237.k100 == "move" then
            v277, v278, v279 = true, v245, v246
            v281 = v165(v237.k76, v68.k32, 0.25, v237.k60)
        elseif v237.k100 == "low" then
            if math.random() < v250 then
                v277 = false
                v281 = v165(v237.k101, v68.k33, 0.15, v237.k60)
            else
                local v283 = v161(v237.k107)
                if math.abs(v283) < 1.6 then
                    v283 = math.pi
                end
                v277, v278, v279 = true, v251 or v258 + v283, v238
                v282 = v278
                v281 = v155(v237.k76, v68.k32, 0.25)
            end
        else
            v277 = false
            v280 = v243 < v237.k105
            v281 = v165(v237.k101, v68.k33, 0.15, v237.k60)
        end
        local v284 = 0
        local v285
        local v286 = v237.k72
        local function v287()
            local v288 = math.abs(v161(v237.k107))
            local v289
            if v286 and v288 < 2.8 then
                v289 = math.random() < v237.k51 and -v286 or v286
            else
                v289 = math.random() < 0.5 and 1 or -1
            end
            v286 = v289
            return v288 * v289
        end
        local v290, v291, v292 = v224.Y, v227, v228
        local function v293(v294)
            if v292 then
                v290 += v291 * v294 - 0.5 * v229 * v294 * v294
                v291 -= v229 * v294
                if v291 < 0 and v290 <= v266 then
                    v290, v291, v292 = v266, 0, false
                    if math.random() < v264 then
                        v292, v291 = true, v265
                    end
                end
            elseif v263 > 0 and math.random() < 1 - math.exp(-v263 * v294) then
                v292, v291 = true, v265
            end
            local v295, v296 = 0, 0
            if v277 then
                v295, v296 = math.cos(v278) * v279, math.sin(v278) * v279
            elseif v280 then
                v295, v296 = v225, v226
            end
            local v297 = math.exp(-v294 / v271)
            local v298 = v271 * (1 - v297)
            v273 += v295 * v294 + (v275 - v295) * v298
            v274 += v296 * v294 + (v276 - v296) * v298
            v275 = v295 + (v275 - v295) * v297
            v276 = v296 + (v276 - v296) * v297
        end
        while v284 < v268 do
            local v299 = math.min(v267, v268 - v284)
            if not v219 and v284 + v299 > v235 then
                v299 = v235 - v284
            end
            local v300 = v299
            while v281 < v300 do
                v293(v281)
                v300 -= v281
                if v277 then
                    if math.random() < v257 then
                        v277 = false
                        v280 = false
                        v282 = v278
                        v281 = v155(v237.k101, v68.k33, 0.15)
                    else
                        v278 += v287()
                        v281 = v155(v237.k76, v68.k32, 0.25)
                    end
                else
                    v277 = true
                    v280 = false
                    v278 = v282 + v161(v237.k99)
                    v279 = v238
                    v281 = v155(v237.k76, v68.k32, 0.25)
                end
            end
            v293(v300)
            v281 -= v300
            v284 += v299
            if v219 then
                if v284 >= v235 then
                    local v301, v302 = v273 - v218.X, v274 - v218.Z
                    if math.sqrt(v301 * v301 + v302 * v302) <= v219 * (v284 - v235) then
                        v285 = { v273, v274, v290 }
                        v270[v272] = v284
                        break
                    end
                end
            elseif v284 >= v235 - 1e-9 then
                v285 = { v273, v274, v290 }
                v270[v272] = v284
                break
            end
        end
        v269[v272] = v285 or { v273, v274, v290 }
        v270[v272] = v270[v272] or v284
    end
    local v303 = v235
    if v219 then
        local v304, v305, v306 = v190(v269, v218, v68.k18)
        local v307, v308, v309 = 0, 0, 0
        for v310 = 1, #v269 do
            local v311, v312 = v269[v310][1] - v304, v269[v310][2] - v305
            if v311 * v311 + v312 * v312 <= v68.k18 ^ 2 then
                v307 += v270[v310]
                v308 += v269[v310][3]
                v309 += 1
            end
        end
        v303 = v309 > 0 and v307 / v309 or v235
        local v313 = (v309 > 0 and v308 / v309 or v224.Y) + v231
        return Vector3.new(v304, v313, v305), v303, v306
    end
    do
        local v314, v315, v316 = v171(v269, v68.k10)
        local v317, v318 = 0, 0
        for v319 = 1, #v269 do
            local v320, v321 = v269[v319][1] - v314, v269[v319][2] - v315
            if v320 * v320 + v321 * v321 <= v68.k10 ^ 2 then
                v317 += v269[v319][3]
                v318 += 1
            end
        end
        return Vector3.new(v314, (v318 > 0 and v317 / v318 or v224.Y) + v231, v315), v303, v316
    end
end

function v68.k87(v322, v323, v324)
    if v322 then
        return v323 >= v68.k20 or v324 >= v68.k17
    end
    return v323 >= v68.k12 or v324 >= v68.k9
end

function v68.k77()
    local v325 = { k95 = {}, k97 = 0 }
    local v326 = 0
    local v327 = v68.k27
    while v327 <= v68.k26 + 1e-9 do
        v326 += 1
        local v328 = (v327 - v68.k28) / v68.k29
        v325.k95[v326] = -0.5 * v328 * v328
        v327 += v68.k30
    end
    return v325
end

function v68.k79(v329, v330, v331, v332, v333, v334, v335, v336)
    local v337 = v330.k73
    if #v337 < 2 then
        return false
    end
    local v338 = v337[#v337].k103
    local v339 = v334 - v333
    local v340, v341 = v339.X, v339.Z
    local v342 = math.sqrt(v340 * v340 + v341 * v341)
    if v342 < 0.5 then
        return false
    end
    v340, v341 = v340 / v342, v341 / v342
    local v343 = v68.k18 + 0.2
    local v344 = {}
    local v345 = 0
    local v346 = v68.k27
    while v346 <= v68.k26 + 1e-9 do
        v345 += 1
        local v347 = false
        local v348 = false
        local v349 = 0
        while v349 <= 1.2 do
            local v350 = v331 + v332 + v346 + v349
            if v350 > v338 then
                break
            end
            v348 = true
            local v351 = v68.k54(v330, v350)
            local v352, v353 = v333.X + v340 * v335 * v349, v333.Z + v341 * v335 * v349
            local v354, v355 = v351.X - v352, v351.Z - v353
            if v354 * v354 + v355 * v355 <= v343 * v343 then
                v347 = true
                break
            end
            v349 += 1 / 60
        end
        if not v348 then
            v344[v345] = 0.5
        elseif v336 then
            v344[v345] = v347 and 0.9 or 0.15
        else
            v344[v345] = v347 and 0.2 or 0.85
        end
        v346 += v68.k30
    end
    local v356, v357 = math.huge, -math.huge
    for _, v358 in v344 do
        v356 = math.min(v356, v358)
        v357 = math.max(v357, v358)
    end
    if v357 - v356 < 0.3 then
        return false
    end
    for v359, v360 in v344 do
        v329.k95[v359] += math.log(v360)
    end
    v329.k97 += 1
    return true
end

function v68.k78(v361, v362, v363, v364, v365, v366, v367)
    local v368 = v362.k73
    if #v368 < 2 then
        return false
    end
    local v369 = v368[#v368].k103
    local v370 = v366 - v365
    local v371, v372 = v370.X, v370.Z
    local v373 = math.sqrt(v371 * v371 + v372 * v372)
    if v373 < 0.5 then
        return false
    end
    v371, v372 = v371 / v373, v372 / v373
    local v374 = false
    local v375 = {}
    local v376 = 0
    local v377 = v68.k27
    while v377 <= v68.k26 + 1e-9 do
        v376 += 1
        local v378 = v363 + v364 + v377
        local v379 = v68.k54(v362, v378)
        local v380
        if v378 > v369 then
            v380 = 0.5
        elseif v367 then
            local v381, v382 = v379.X - v366.X, v379.Z - v366.Z
            local v383 = math.sqrt(v381 * v381 + v382 * v382)
            local v384 = math.max(0, v383 - 1.3)
            v380 = 0.08 + 0.92 * math.exp(-v384 * v384 / 0.32)
        else
            local v385, v386 = v379.X - v365.X, v379.Z - v365.Z
            local v387 = v385 * v371 + v386 * v372
            local v388 = math.abs(v385 * v372 - v386 * v371)
            if v387 > 0 and v387 < v373 + 2 and v388 < 1.0 then
                v380 = 0.25
            else
                v380 = 0.85
            end
        end
        v375[v376] = v380
        v377 += v68.k30
    end
    local v389, v390 = math.huge, -math.huge
    for _, v391 in v375 do
        v389 = math.min(v389, v391)
        v390 = math.max(v390, v391)
    end
    v374 = v390 - v389 > 0.3
    if not v374 then
        return false
    end
    for v392, v393 in v375 do
        v361.k95[v392] += math.log(v393)
    end
    v361.k97 += 1
    return true
end

function v68.k81(v394)
    if v394.k97 < v68.k22 then
        return nil
    end
    local v395, v396 = 1, -math.huge
    for v397, v398 in v394.k95 do
        if v398 > v396 then
            v395, v396 = v397, v398
        end
    end
    return v68.k27 + (v395 - 1) * v68.k30
end

function v68.k52(v399)
    local v400 = v68.k81(v399)
    if v400 then
        v68.k14 = math.clamp(v400 - v68.k35, v68.k27, v68.k26)
    end
    return v400
end

local v401 = 96
v12(v5:GetInstanceAddedSignal("ThrowingKnife"):Connect(function(v402)
    local v403 = v402:GetAttribute("ThrowSpeed")
    if type(v403) == "number" and v403 > 0 then
        v401 = v403
    end
end))

local v404 = 0.12
local function v405()
    local v406, v407 = pcall(function()
        return v6.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if v406 and type(v407) == "number" and v407 > 0 then
        return v407 / 1000
    end
    local v408, v409 = pcall(v8.GetNetworkPing, v8)
    if v408 and type(v409) == "number" and v409 > 0 then
        return v409 * 2
    end
    return nil
end
task.spawn(function()
    while not v10 do
        local v410 = v405()
        if v410 then
            v404 += (math.clamp(v410, 0, 0.6) - v404) * 0.35
        end
        v68.k8 = v7.Gravity
        task.wait(0.5)
    end
end)

local v411 = v7.Raycast
local v412 = RaycastParams.new()
v412.FilterType = Enum.RaycastFilterType.Exclude
local v413 = RaycastParams.new()
v413.FilterType = Enum.RaycastFilterType.Exclude
local function v414()
    local v415 = {}
    for _, v416 in v1:GetPlayers() do
        if v416.Character then
            table.insert(v415, v416.Character)
        end
    end
    for _, v417 in v5:GetTagged("WeaponPassthrough") do
        table.insert(v415, v417)
    end
    v412.FilterDescendantsInstances = v415
    v413.FilterDescendantsInstances = v46()
end
v414()

local v418 = {}
local v419 = { k68 = nil, k106 = nil, k91 = nil, k55 = nil }
local v420
local v421 = {}
local v422
local v423

local v424 = 3
local v425 = v9.__c47
if type(v425) ~= "table" or v9.__c48 ~= game.JobId or v9.__c49 ~= v424 then
    v425 = v68.k77()
    v9.__c47, v9.__c48, v9.__c49 = v425, game.JobId, v424
end
local function v426()
    v68.k52(v425)
end
v426()

local function v427(v428)
    return (v428 == "Gun" and v15.k13) or (v428 == "Knife" and v15.k21)
end

local function v429()
    local v430 = v8.Character
    local v431 = v430 and v430:FindFirstChildOfClass("Tool")
    if v431 == v419.k106 and (not v431 or v419.k91 and v419.k91.Parent) then
        return
    end
    v419.k106, v419.k68, v419.k91 = v431, nil, nil
    if v431 then
        if v28(v431) then
            local v432 = v431:FindFirstChild("Events")
            v419.k68 = "Knife"
            v419.k91 = v432 and v432:FindFirstChild("KnifeThrown")
        elseif v25(v431) then
            v419.k68 = "Gun"
            v419.k91 = v431:FindFirstChild("Shoot")
        end
    end
    local v433 = v430 and v430:FindFirstChild("HumanoidRootPart")
    v419.k55 = v433 and v433:FindFirstChild("GunRaycastAttachment")
end

local function v434(v435, v436)
    if typeof(v436) == "CFrame" then
        return v436.Position
    end
    if v435 == "Gun" and v419.k55 then
        return v419.k55.WorldPosition
    end
    local v437 = v419.k106 and v419.k106:FindFirstChild("Handle")
    return v437 and v437.Position
end

local function v438(v439, v440)
    for _, v441 in { "HumanoidRootPart", "Head", "UpperTorso", "Torso", "LowerTorso", "LeftUpperLeg", "RightUpperLeg" } do
        local v442 = v440:FindFirstChild(v441)
        if v442 then
            local v443 = v411(v7, v439, v442.Position - v439, v412)
            if not v443 then
                return true
            end
            if v443.Instance.Transparency >= 1 and v50(v439, v442.Position, v440) then
                return true
            end
        end
    end
    return false
end

local function v444(v445)
    table.clear(v421)
    local v446 = v41(v8)
    if not v446 then
        return nil
    end
    local v447 = v7.CurrentCamera
    local v448 = v65()
    local v449 = math.max(v447.ViewportSize.Magnitude, 1)
    local v450 = v8.Character:FindFirstChild("Head")
    local v451 = v434(v445) or (v450 and v450.Position) or v446.Position
    local v452, v453, v454, v455 = false, nil, nil, nil
    for _, v456 in v1:GetPlayers() do
        if v456 ~= v8 then
            local v457, _, v458 = v41(v456)
            local v459, v460 = v35(v456)
            if v457 and not v460 then
                if v459 == "Murderer" then
                    v452 = true
                end
                if v438(v451, v458) then
                    local v461, v462 = v447:WorldToViewportPoint(v457.Position)
                    local v463 = (v457.Position - v446.Position).Magnitude
                    local v464
                    if v462 and v461.Z > 0 then
                        v464 = (Vector2.new(v461.X, v461.Y) - v448).Magnitude
                    else
                        v464 = v449 + v463
                    end
                    local v465 = v459 == "Sheriff" or v459 == "Hero"
                    local v466 = { k84 = v456, k92 = v457, k57 = v458, k80 = math.clamp(v464 / v449, 0, 2), k85 = v465 }
                    if v459 == "Murderer" then
                        v453 = v466
                    end
                    table.insert(v421, v466)
                    local v467 = v464 + v463 * 3
                    if v445 == "Knife" and v465 then
                        v467 -= 120
                    end
                    if v420 and v420.k84 == v456 then
                        v467 -= 40
                    end
                    if not v455 or v467 < v455 then
                        v454, v455 = v466, v467
                    end
                end
            end
        end
    end
    if v445 == "Gun" and v452 then
        table.clear(v421)
        if v453 then
            table.insert(v421, v453)
        end
        return v453
    end
    return v454
end

local function v468(v469, v470, v471, v472)
    local v473 = v411(v7, v469, v470 - v469, v412)
    if v473 and v473.Instance.Transparency < 1 then
        return false
    end
    if v471 then
        local v474 = v472 or v470
        local v475 = v411(v7, v469, v474 - v469, v413)
        if v475 and not v475.Instance:IsDescendantOf(v471) then
            local v476 = v475.Instance:FindFirstAncestorOfClass("Model")
            if v476 and v476:FindFirstChildOfClass("Humanoid") and v1:GetPlayerFromCharacter(v476) then
                return false
            end
        end
    end
    return true
end
local function v477(v478, v479, v480)
    local v481 = v479 - v478
    if v481.Magnitude < 0.1 then
        return v479
    end
    return v479 + v481.Unit * math.clamp((v480 or 0) + 2, 4, 10)
end

local function v482(v483, v484, v485)
    if not v483 or not v483.k92.Parent then
        return nil
    end
    local v486 = v418[v483.k84]
    if not v486 or v486.k92 ~= v483.k92 or #v486.k73 < 2 then
        return nil
    end
    local v487, _, v488, v489 = v68.k50(v486, v485, v484 == "Knife" and v401 or nil, v404)
    if not v487 then
        return nil
    end
    local v490 = v486.k73[#v486.k73].k83
    local v491 = v487 - v490
    if v491.Magnitude > 0.5 then
        local v492 = v411(v7, v490, v491, v412)
        if v492 and v492.Instance.CanCollide then
            v487 = v492.Position - v491.Unit * 1.5
        end
    end
    local function v493(v494)
        return v468(v485, v494, v483.k57, v484 == "Gun" and v477(v485, v494, v489) or nil)
    end
    if not v493(v487) then
        local v495 = v487 - v485
        local v496 = Vector3.new(-v495.Z, 0, v495.X)
        v496 = v496.Magnitude > 0.01 and v496.Unit or Vector3.new(1, 0, 0)
        for _, v497 in {
            Vector3.new(0, 0.8, 0), Vector3.new(0, 1.6, 0), Vector3.new(0, -1.0, 0), Vector3.new(0, -2.0, 0),
            v496 * 0.7, -v496 * 0.7, v496 * 0.6 + Vector3.new(0, 0.8, 0), -v496 * 0.6 + Vector3.new(0, 0.8, 0),
            v496 * 0.6 - Vector3.new(0, 1.0, 0), -v496 * 0.6 - Vector3.new(0, 1.0, 0),
        } do
            local v498 = v487 + v497
            if v493(v498) then
                v487 = v498
                break
            end
        end
    end
    return v487, v488, v489
end

local function v499(v500, v501)
    if v500 == "Knife" and #v421 > 1 then
        local v502, v503, v504, v505, v506
        for _, v507 in v421 do
            local v508, v509, v510 = v482(v507, v500, v501)
            if v508 then
                local v511 = v509 - 0.05 * v507.k80 + (v507.k85 and 0.08 or 0)
                if not v505 or v511 > v505 then
                    v502, v503, v504, v505, v506 = v507, v508, v509, v511, v510
                end
            end
        end
        if v502 then
            return v503, v504, v502, v506
        end
    end
    local v512, v513, v514 = v482(v420, v500, v501)
    return v512, v513, v420, v514
end

local function v515(v516, v517, v518, v519)
    if v516 == "Gun" then
        return CFrame.new(v477(v517, v518, v519))
    end
    return CFrame.new(v518)
end

local function v520(v521, v522)
    local v523 = v521.FireServer
    return v523(v521, table.unpack(v522, 1, v522.n))
end

local function v524(v525, v526, v527, v528)
    local v529 = v526 and v418[v526.k84]
    if not v529 then
        return
    end
    local v530 = { k68 = v525, k103 = os.clock(), k93 = v404, k82 = v527, k50 = v528, k89 = v529, k57 = v526.k57, k106 = v419.k106 }
    if v525 == "Gun" then
        v423 = v530
        return
    end
    task.delay(1.9, function()
        if v10 then
            return
        end
        local v531 = v529.k59
        local v532 = v531 ~= nil and v531 >= v530.k103 and v531 <= v530.k103 + 1.7
        if v68.k79(v425, v529, v530.k103, v530.k93, v530.k82, v530.k50, v401, v532) then
            v426()
        end
    end)
end

local function v533(v534, v535, v536, v537)
    local v538 = v423
    if not v538 or v534 ~= v538.k106 or typeof(v536) ~= "Vector3" or os.clock() - v538.k103 > 1.5 then
        return
    end
    v423 = nil
    local v539 = v538.k82
    if typeof(v535) == "Vector3" then
        v539 = v535
    elseif typeof(v535) == "Instance" then
        if v535:IsA("Attachment") then
            v539 = v535.WorldPosition
        elseif v535:IsA("BasePart") then
            v539 = v535.Position
        end
    end
    local v540 = typeof(v537) == "Instance" and v538.k57 ~= nil and v537:IsDescendantOf(v538.k57)
    task.delay(1.1, function()
        if v10 then
            return
        end
        if v68.k78(v425, v538.k89, v538.k103, v538.k93, v539, v536, v540) then
            v426()
        end
    end)
end
task.spawn(function()
    local v541 = v3:WaitForChild("ClientServices", 10)
    local v542 = v541 and v541:WaitForChild("WeaponService", 10)
    local v543 = v542 and v542:WaitForChild("GunFired", 10)
    if v543 and not v10 then
        v12(v543.OnClientEvent:Connect(function(...)
            pcall(v533, ...)
        end))
    end
end)

local function v544(v545)
    v422 = nil
    local v546 = v545.k53
    if v545.k68 == "Gun" and v419.k55 and typeof(v546[1]) == "CFrame" then
        v546[1] = v419.k55.WorldCFrame
    end
    local v547 = v434(v545.k68, v546[1]) or v545.k82
    local v548, _, v549, v550 = v499(v545.k68, v547)
    if v548 then
        v546[2] = v515(v545.k68, v547, v548, v550)
    elseif v545.k50 then
        v546[2] = v545.k50
    end
    if pcall(v520, v545.k91, v546) and typeof(v546[2]) == "CFrame" then
        v524(v545.k68, v549 or v545.k61, v547, v546[2].Position)
    end
end

local v551 = 0
v12(v2.PreSimulation:Connect(function()
    if v10 then
        return
    end
    if not (v15.k13 or v15.k21) then
        if next(v418) then
            table.clear(v418)
        end
        v420 = nil
        table.clear(v421)
        if v422 then
            v544(v422)
        end
        return
    end
    local v552 = os.clock()
    for _, v553 in v1:GetPlayers() do
        if v553 ~= v8 then
            local v554 = v553.Character
            local v555 = v554 and v554:FindFirstChild("HumanoidRootPart")
            local v556 = v554 and v554:FindFirstChildOfClass("Humanoid")
            if v555 and v556 then
                local v557 = v418[v553]
                if not v557 or v557.k92 ~= v555 then
                    v557 = v68.new()
                    v557.k92 = v555
                    v418[v553] = v557
                end
                if v556.Health <= 0 then
                    v557.k59 = v557.k59 or v552
                end
                if v556.UseJumpPower then
                    v557.k67 = v556.JumpPower
                else
                    v557.k67 = math.sqrt(2 * v7.Gravity * v556.JumpHeight)
                end
                if not v557.k59 or v552 - v557.k59 < 0.6 then
                    local v558 = v556:GetState()
                    local v559 = v556.FloorMaterial ~= Enum.Material.Air
                        or (v558 ~= Enum.HumanoidStateType.Freefall and v558 ~= Enum.HumanoidStateType.Jumping)
                    v68.k86(v557, v552, v555.Position, v559)
                end
            else
                v418[v553] = nil
            end
        end
    end
    v551 += 1
    if v551 % 60 == 0 then
        v414()
    end
    v429()
    if v419.k68 and v427(v419.k68) then
        v420 = v444(v419.k68)
    else
        v420 = nil
        table.clear(v421)
    end
    local v560 = v422
    if v560 then
        if v560.k91 ~= v419.k91 or not v420 then
            v544(v560)
        else
            local v561 = v434(v560.k68, v419.k55 and v419.k55.WorldCFrame) or v560.k82
            local _, v562 = v499(v560.k68, v561)
            if not v562 or v68.k87(v560.k68 == "Knife", v562, v552 - v560.k98) then
                v544(v560)
            end
        end
    end
end))
v12(v1.PlayerRemoving:Connect(function(v563)
    v418[v563] = nil
end))

local function v564(v565, v566)
    local v567 = v419.k68
    local v568 = v434(v567, v566[1])
    if not v568 then
        return false
    end
    local v569, v570, v571, v572 = v499(v567, v568)
    if not v569 then
        return false
    end
    local v573 = v515(v567, v568, v569, v572)
    if not v68.k87(v567 == "Knife", v570, 0) then
        if v422 then
            v544(v422)
        end
        v422 = { k91 = v565, k53 = v566, k68 = v567, k82 = v568, k50 = v573, k61 = v571, k98 = os.clock() }
        return true
    end
    v566[2] = v573
    v520(v565, v566)
    v524(v567, v571, v568, v573.Position)
    return true
end

local v574 = false
if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local v575
    local v576 = typeof(checkcaller) == "function" and checkcaller or function()
        return false
    end
    local function v577(self, ...)
        if v10 or self ~= v419.k91 then
            return v575(self, ...)
        end
        if getnamecallmethod() ~= "FireServer" or v576() or not v427(v419.k68) then
            return v575(self, ...)
        end
        local v578 = table.pack(...)
        local v579, v580 = pcall(v564, self, table.pack(...))
        if v579 and v580 then
            return nil
        end
        return v520(self, v578)
    end
    if typeof(newcclosure) == "function" then
        v577 = newcclosure(v577)
    end
    v575 = hookmetamethod(game, "__namecall", v577)
    v574 = true
end

local v581
pcall(function()
    v581 = require(v3:WaitForChild("ClientServices", 5):WaitForChild("WeaponService", 5))
end)
local v582, v583
if not v574 and type(v581) == "table" then
    v582, v583 = v581.GetMouseTargetCFrame, v581.GetTargetPosition
    local function v584()
        local v585 = v419.k68
        if v10 or not v585 or not v427(v585) then
            return nil
        end
        local v586 = v434(v585)
        if not v586 then
            return nil
        end
        local v587, _, _, v588 = v499(v585, v586)
        return v587 and v515(v585, v586, v587, v588)
    end
    v581.GetMouseTargetCFrame = function(self, ...)
        local v589, v590 = pcall(v584)
        if v589 and v590 then
            return v590
        end
        return v582(self, ...)
    end
    v581.GetTargetPosition = function(self, v591, v592, ...)
        v58, v59 = Vector2.new(v591, v592), os.clock()
        local v593, v594 = pcall(v584)
        if v593 and v594 then
            return v594
        end
        return v583(self, v591, v592, ...)
    end
end

local v595 = Instance.new("Folder")
v595.Name = "\0"
v595.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
local v596 = {}
local v597 = {
    Murderer = Color3.fromRGB(255, 50, 50),
    Sheriff = Color3.fromRGB(50, 140, 255),
    Hero = Color3.fromRGB(50, 140, 255),
    Innocent = Color3.fromRGB(60, 230, 90),
}
local function v598(v599)
    local v600 = v596[v599]
    if v600 then
        v600.k66:Destroy()
        v600.k56:Destroy()
        v596[v599] = nil
    end
end
v12(v1.PlayerRemoving:Connect(v598))
local function v601()
    for _, v602 in v1:GetPlayers() do
        if v602 ~= v8 then
            local v603, _, v604 = v41(v602)
            local v605, v606 = v35(v602)
            if v15.k5 and v603 and not v606 then
                local v607 = v597[v605] or v597.Innocent
                local v608 = v596[v602]
                if not v608 or v608.k57 ~= v604 then
                    v598(v602)
                    local v609 = Instance.new("Highlight")
                    v609.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    v609.FillTransparency = 0.55
                    v609.OutlineTransparency = 0
                    v609.Adornee = v604
                    v609.Parent = v595
                    local v610 = Instance.new("BillboardGui")
                    v610.AlwaysOnTop = true
                    v610.Size = UDim2.fromOffset(160, 22)
                    v610.StudsOffset = Vector3.new(0, 3.4, 0)
                    v610.Adornee = v603
                    v610.Parent = v595
                    local v611 = Instance.new("TextLabel")
                    v611.BackgroundTransparency = 1
                    v611.Size = UDim2.fromScale(1, 1)
                    v611.Font = Enum.Font.GothamBold
                    v611.TextSize = 13
                    v611.TextStrokeTransparency = 0.4
                    v611.Text = v602.DisplayName
                    v611.Parent = v610
                    v608 = { k66 = v609, k56 = v610, k69 = v611, k57 = v604 }
                    v596[v602] = v608
                end
                if v608.k58 ~= v607 then
                    v608.k58 = v607
                    v608.k66.FillColor = v607
                    v608.k66.OutlineColor = v607
                    v608.k69.TextColor3 = v607
                end
            else
                v598(v602)
            end
        end
    end
end
task.spawn(function()
    while not v10 do
        pcall(v601)
        task.wait(0.25)
    end
end)

local v612 = {}
local v613 = {}
local v614
local function v615(v616)
    local v617 = v613[v616]
    if v617 then
        return v617
    end
    local v618 = {}
    for _, v619 in v616:GetDescendants() do
        if v619:IsA("BasePart") then
            table.insert(v618, v619)
        end
    end
    v613[v616] = v618
    local v620
    v620 = v616.DescendantAdded:Connect(function(v621)
        if v621:IsA("BasePart") then
            table.insert(v618, v621)
        end
    end)
    v616.AncestryChanged:Once(function()
        v613[v616] = nil
        v620:Disconnect()
    end)
    return v618
end
v12(v2.PreSimulation:Connect(function()
    if not v15.k4 then
        v614 = nil
        return
    end
    local v622, v623 = v41(v8)
    local v624 = os.clock()
    for _, v625 in v1:GetPlayers() do
        if v625 ~= v8 then
            local v626 = v625.Character
            local v627 = v626 and v626:FindFirstChild("HumanoidRootPart")
            if v627 and v622 then
                local v628 = v627.Position - v622.Position
                if v628.X * v628.X + v628.Y * v628.Y + v628.Z * v628.Z < 3600 then
                    local v629 = v627.AssemblyAngularVelocity
                    local v630 = v627.AssemblyLinearVelocity
                    if v629:Dot(v629) > 625 or v630:Dot(v630) > 14400 then
                        v612[v625] = v624 + 3
                    end
                end
            end
            local v631 = v612[v625]
            if v631 then
                if v624 > v631 or not v626 then
                    v612[v625] = nil
                else
                    for _, v632 in v615(v626) do
                        if v632.CanCollide then
                            v632.CanCollide = false
                        end
                    end
                end
            end
        end
    end
    if not v622 then
        v614 = nil
        return
    end
    local v633 = v622.AssemblyLinearVelocity
    local v634 = math.sqrt(v633.X * v633.X + v633.Z * v633.Z)
    local v635 = v622.AssemblyAngularVelocity.Magnitude
    local v636 = v623.WalkSpeed
    if (v634 > math.max(v636 * 5, 90) or v633.Y > 140 or v635 > 35) and v614 then
        v622.AssemblyLinearVelocity = Vector3.zero
        v622.AssemblyAngularVelocity = Vector3.zero
        v622.CFrame = v614
    elseif v634 < v636 * 2 + 4 and v635 < 8 and math.abs(v633.Y) < 60 then
        v614 = v622.CFrame
    end
end))

local v637 = v14:CreateWindow({
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

local v638 = "\u{200B}\u{200C}\u{200B}"
pcall(function()
    v637:EditOpenButton({
        Title = v638,
        Icon = "",
        Transparency = 1,
        StrokeThickness = 0,
    })
end)
local v639 = {}
local function v640()
    local v641 = { game:GetService("CoreGui") }
    if typeof(gethui) == "function" then
        table.insert(v641, gethui())
    end
    local v642 = v8:FindFirstChildOfClass("PlayerGui")
    if v642 then
        table.insert(v641, v642)
    end
    local v643 = false
    for _, v644 in v641 do
        local v645, v646 = pcall(v644.GetDescendants, v644)
        if v645 then
            for _, v647 in v646 do
                if (v647:IsA("TextLabel") or v647:IsA("TextButton")) and v647.Text == v638 then
                    local v648 = v647
                    local v649 = v647.Parent
                    while v649 and v649:IsA("GuiObject") and v649.AbsoluteSize.X * v649.AbsoluteSize.Y < 320 * 160 do
                        v648 = v649
                        v649 = v649.Parent
                    end
                    if v648:IsA("GuiObject") and not v639[v648] then
                        v639[v648] = true
                        v648.Visible = false
                        v12(v648:GetPropertyChangedSignal("Visible"):Connect(function()
                            if v648.Visible then
                                v648.Visible = false
                            end
                        end))
                    end
                    v643 = true
                end
            end
        end
    end
    return v643
end
task.spawn(function()
    for _, v650 in { 0.2, 0.5, 1, 2, 4, 8 } do
        task.wait(v650)
        if v10 then
            return
        end
        local v651, v652 = pcall(v640)
        if v651 and v652 then
            return
        end
    end
end)
local v653 = Enum.KeyCode.K
v12(v4.InputBegan:Connect(function(v654)
    if v654.KeyCode == v653 then
        task.delay(0.15, pcall, v640)
        task.delay(0.6, pcall, v640)
    end
end))

local v655 = v637:Tab({ Title = "Main", Icon = "crosshair" })
v655:Section({ Title = "Silent Aim" })
v655:Toggle({
    Title = "Gun Silent Aim",
    Default = false,
    Callback = function(v656)
        v15.k13 = v656
    end,
})
v655:Toggle({
    Title = "Murderer Silent Aim",
    Default = false,
    Callback = function(v657)
        v15.k21 = v657
    end,
})
v655:Section({ Title = "Other" })
v655:Toggle({
    Title = "ESP",
    Default = false,
    Callback = function(v658)
        v15.k5 = v658
    end,
})
v655:Toggle({
    Title = "Anti Fling",
    Default = false,
    Callback = function(v659)
        v15.k4 = v659
        if not v659 then
            table.clear(v612)
        end
    end,
})

local v660 = v637:Tab({ Title = "Settings", Icon = "settings" })
local v661 = v660:Keybind({
    Title = "Toggle UI",
    Callback = function(v662)
        local v663 = typeof(v662) == "EnumItem" and v662 or Enum.KeyCode[tostring(v662)]
        if v663 then
            v653 = v663
            pcall(v637.SetToggleKey, v637, v663)
        end
    end,
})
pcall(function()
    v661:SetValue("K")
end)

v9.__c46 = function()
    v10 = true
    if v422 then
        pcall(v544, v422)
    end
    for _, v664 in v11 do
        pcall(v664.Disconnect, v664)
    end
    for v665 in v596 do
        v598(v665)
    end
    v595:Destroy()
    if v582 and v581 then
        v581.GetMouseTargetCFrame = v582
        v581.GetTargetPosition = v583
    end
    pcall(v637.Close, v637)
end
