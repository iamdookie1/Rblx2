local v1 = game:GetService("Players")
local v2 = game:GetService("RunService")
local v3 = game:GetService("ReplicatedStorage")
local v4 = game:GetService("UserInputService")
local v5 = game:GetService("CollectionService")
local v6 = game:GetService("Stats")
local v7 = workspace
local v8 = v1.LocalPlayer

local v9 = (typeof(getgenv) == "function" and getgenv()) or _G
if v9.__c49 then
    pcall(v9.__c49)
end

local v10 = false
local v11 = {}
local function v12(v13)
    table.insert(v11, v13)
    return v13
end

local v14 = loadstring(game:HttpGet("https://github.com/SSHRKs/LumeUI/releases/latest/download/main.lua"))()

local v15 = {
    k15 = false,
    k23 = false,
    k7 = false,
    k4 = false,
    k47 = false,
    k6 = "Spoof",
    k5 = 8,
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
    k48 = 3.0,
    k39 = 0.034,
    k8 = 0.067,
    k10 = 196.2,
    k16 = 0.06,
    k37 = 0.01,
    k9 = 80,
    k40 = 1 / 30,
    k27 = 2.0,
    k26 = 0.4,
    k44 = 0.7,
    k25 = 0.1,
    k33 = 0.12,
    k34 = 1.5,
    k35 = 0.8,
    k36 = 1.5,
    k41 = 0.5,
    k46 = 0.7,
    k43 = 3,
    k42 = 0.9,
    k17 = 0.2,
    k1 = 0.05,
    k2 = 40,
    k45 = 0.035,
    k3 = 0.05,
    k12 = 1.0,
    k18 = 3,
    k38 = 0.2,
    k20 = 1.2,
    k11 = 0.5,
    k14 = 0.95,
    k19 = 0.35,
    k22 = 0.75,
    k13 = 0.3,
    k21 = -0.5,
    k29 = -0.3,
    k28 = 0.4,
    k32 = 0.005,
    k30 = 0.07,
    k31 = 0.12,
    k24 = 2,
}

function v68.new()
    return { k76 = {}, k67 = nil, k68 = true, k107 = {}, k74 = {}, k70 = 50 }
end

function v68.k89(v69, v70, v71, v72)
    local v73 = v69.k76
    local v74 = #v73
    if v74 > 0 and v70 <= v73[v74].k106 then
        return
    end
    v73[v74 + 1] = { k106 = v70, k86 = v71 }
    v74 += 1
    if v72 then
        v69.k67 = v71.Y
    end
    if v69.k68 and not v72 then
        local v75 = v69.k73 ~= nil and v70 - v69.k73 < 0.2
        table.insert(v69.k107, { k106 = v70, k91 = v75 })
    elseif v72 and not v69.k68 then
        v69.k73 = v70
        table.insert(v69.k74, v70)
    end
    local v76 = v70 - v68.k18
    while v69.k107[1] and v69.k107[1].k106 < v76 do
        table.remove(v69.k107, 1)
    end
    while v69.k74[1] and v69.k74[1] < v76 do
        table.remove(v69.k74, 1)
    end
    v69.k68 = v72
    local v77 = v70 - v68.k48 - 0.2
    local v78 = 0
    while v78 < v74 - 2 and v73[v78 + 1].k106 < v77 do
        v78 += 1
    end
    if v78 > 0 then
        table.move(v73, v78 + 1, v74, 1)
        for v79 = v74 - v78 + 1, v74 do
            v73[v79] = nil
        end
    end
end

function v68.k57(v80, v81)
    local v82 = v80.k76
    local v83 = #v82
    if v81 >= v82[v83].k106 then
        return v82[v83].k86
    end
    if v81 <= v82[1].k106 then
        return v82[1].k86
    end
    local v84, v85 = 1, v83
    while v85 - v84 > 1 do
        local v86 = (v84 + v85) // 2
        if v82[v86].k106 <= v81 then
            v84 = v86
        else
            v85 = v86
        end
    end
    local v87, v88 = v82[v84], v82[v85]
    return v87.k86 + (v88.k86 - v87.k86) * ((v81 - v87.k106) / math.max(v88.k106 - v87.k106, 1e-6))
end

function v68.k112(v89, v90, v91)
    return (v68.k57(v89, v90) - v68.k57(v89, v90 - v91)) / v91
end

local function v92(v93)
    v93 = (v93 + math.pi) % (2 * math.pi)
    return v93 - math.pi
end

function v68.k66(v94, v95, v96)
    local v97, v98, v99, v100, v101, v102, v103 = 0, 0, 0, 0, 0, 0, 0
    for v104 = 0, 4 do
        local v105 = -v96 * v104 / 4
        local v106 = v68.k57(v94, v95 + v105)
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

function v68.k78(v108)
    local v109 = v108.k76
    local v110 = v109[#v109].k106
    local v111 = math.max(v109[1].k106 + v68.k39, v110 - v68.k48)
    local v112 = {}
    local v113 = v111
    while v113 <= v110 + 1e-6 do
        local v114 = v68.k112(v108, v113, v68.k39)
        v112[#v112 + 1] = { k106 = v113, k113 = v114.X, k114 = v114.Z, k97 = math.sqrt(v114.X * v114.X + v114.Z * v114.Z) }
        v113 += 1 / 60
    end
    local v115 = {}
    for _, v116 in v112 do
        if v116.k97 > v68.k27 then
            v115[#v115 + 1] = v116.k97
        end
    end
    table.sort(v115)
    local v117 = #v115 >= 6 and v115[math.max(1, math.floor(#v115 * 0.7))] or 16
    local v118 = math.max(v68.k27, v117 * v68.k26)
    local v119 = v68.k3
    local v120 = v119 * math.log(1 / v68.k26) + v68.k39 / 2
    local v121 = v119 * math.log(1 / (1 - v68.k26)) + v68.k39 / 2
    local v122 = {
        k79 = {}, k104 = {}, k110 = {}, k102 = {},
        k105 = 0, k99 = 0, k65 = 0,
        k111 = v117, k108 = v118,
    }
    local v123, v124, v125, v126, v127, v128
    local v129, v130, v131
    local v132 = {}
    local v133
    for _, v134 in v112 do
        local v135 = v134.k97 > v118
        local v136 = v135 and math.atan2(v134.k114, v134.k113) or nil
        if not v123 then
            v123 = v135 and "move" or "stop"
            v124, v125 = v134.k106, false
            if v135 then
                v126 = v136
                v127, v128 = math.cos(v136), math.sin(v136)
            end
        elseif v123 == "move" then
            if v135 then
                table.insert(v132, v134)
                local v137 = v92(v136 - v126)
                if math.abs(v137) > v68.k44 then
                    local v138 = math.abs(v137) / 2
                    local v139 = v134.k106
                    for _, v140 in v132 do
                        local v141 = v140.k113 * v127 + v140.k114 * v128
                        local v142 = math.abs(v140.k113 * v128 - v140.k114 * v127)
                        if math.atan2(v142, v141) >= v138 then
                            v139 = v140.k106
                            break
                        end
                    end
                    v139 -= v68.k45 + v68.k39 / 2
                    local v143 = v122.k110[#v122.k110]
                    if v133 and v143 and v139 - v133 < v68.k25 and (v143 > 0) == (v137 > 0) and math.abs(v143 + v137) <= math.pi + 0.3 then
                        if math.abs(v143) <= 1.6 and math.abs(v143 + v137) > 1.6 then
                            v122.k99 += 1
                        end
                        v122.k110[#v122.k110] = v143 + v137
                    else
                        if v125 then
                            table.insert(v122.k79, v139 - v124)
                        end
                        table.insert(v122.k110, v137)
                        v122.k65 += 1
                        if math.abs(v137) > 1.6 then
                            v122.k99 += 1
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
                v129 = v134.k106
                v130 = v134.k106 - v120
                v131 = v126
            end
        elseif v123 == "low" then
            if v135 then
                local v144 = v92(v136 - v131)
                if v134.k106 - v129 < v68.k33 then
                    if math.abs(v144) > v68.k44 then
                        local v145 = (v130 + v134.k106 - v121) / 2
                        if v125 then
                            table.insert(v122.k79, v145 - v124)
                        end
                        table.insert(v122.k110, v144)
                        v122.k65 += 1
                        if math.abs(v144) > 1.6 then
                            v122.k99 += 1
                        end
                        v124, v125 = v145, true
                    end
                else
                    local v146 = v134.k106 - v121
                    if v125 then
                        table.insert(v122.k79, v130 - v124)
                    end
                    table.insert(v122.k104, v146 - v130)
                    table.insert(v122.k102, v144)
                    v122.k105 += 1
                    v122.k65 += 1
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
                v124, v125 = v134.k106 - v121, false
                v126 = v136
                v127, v128 = math.cos(v136), math.sin(v136)
                v132 = {}
            end
        end
    end
    local v147, v148 = 0, 0
    for v149 = 2, #v122.k110 do
        local v150, v151 = v122.k110[v149 - 1], v122.k110[v149]
        if math.abs(v150) < 2.8 and math.abs(v151) < 2.8 then
            if (v150 > 0) == (v151 > 0) then
                v147 += 1
            else
                v148 += 1
            end
        end
    end
    v122.k54 = (v148 + 1) / (v148 + v147 + 2)
    local v152 = v122.k110[#v122.k110]
    v122.k75 = v152 and (v152 > 0 and 1 or -1) or nil
    v122.k103 = v123
    v122.k93 = v126
    if v123 == "move" then
        v122.k63 = v110 - v124
    elseif v123 == "low" then
        v122.k77 = v110 - v129
        v122.k63 = v110 - v130
        v122.k93 = v131
        if v122.k77 >= v68.k33 then
            v122.k103 = "stop"
        end
    else
        v122.k63 = v110 - v111
    end
    return v122
end

local function v153(v154)
    if v154 >= v68.k43 then
        return v68.k42
    end
    return v154 / (v154 + v68.k36)
end

local function v155(v156, v157, v158)
    local v159 = #v156
    if v159 > 0 and math.random() < v153(v159) then
        local v160 = math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
        return math.max(0.02, v156[math.random(1, v159)] * math.exp(v68.k17 * v160))
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

function v68.k53(v217, v218, v219, v220)
    local v221 = v217.k76
    local v222 = #v221
    if v222 == 0 then
        return nil
    end
    local v223 = v221[v222].k106
    local v224 = v221[v222].k86
    local v225, v226 = v68.k66(v217, v223, v68.k8)
    local v227 = v68.k112(v217, v223, 0.035).Y
    local v228 = math.abs(v227) > 6 or (not v217.k68 and v217.k67 ~= nil and v224.Y > v217.k67 + 0.5)
    local v229 = v68.k10
    local v230 = v217.k67
    local v231 = v219 and v68.k21 or v68.k13
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
    local v235 = math.max(0, v220 + v68.k16 + v68.k37)
    if v222 < 8 then
        local v236 = v235
        if v219 then
            v236 = v235 + (v224 - v218).Magnitude / v219
        end
        return Vector3.new(v224.X + v225 * v236, v232(v236), v224.Z + v226 * v236), v236, 1
    end
    local v237 = v68.k78(v217)
    local v238 = v237.k111
    local v239 = v68.k112(v217, v223, v68.k39)
    local v240 = v68.k112(v217, v223 - v68.k39, v68.k39)
    local v241, v242 = (v239.X - v240.X) / v68.k39, (v239.Z - v240.Z) / v68.k39
    local v243 = math.sqrt(v225 * v225 + v226 * v226)
    local v244 = v243 > 0.5 and (v241 * v225 + v242 * v226) / v243 or 0
    local v245 = math.atan2(v226, v225)
    local v246 = v243
    if v237.k103 == "move" then
        local v247, v248 = v239.X + v241 * v68.k1, v239.Z + v242 * v68.k1
        local v249 = math.sqrt(v247 * v247 + v248 * v248)
        if math.sqrt(v241 * v241 + v242 * v242) > v68.k2 and v249 > v237.k108 then
            v245 = math.atan2(v248, v247)
            if v243 < v238 * 0.85 and v249 > v243 then
                v246 = math.min(v249, v238)
            end
        end
        if v244 > v68.k2 and v243 < v238 * 0.85 then
            v246 = v238
        end
    end
    local v250 = (v237.k105 + v68.k41) / (v237.k105 + v237.k99 + v68.k41 + v68.k46)
    local v251
    if v237.k103 == "low" then
        local v252, v253 = v239.X + v241 * v68.k1, v239.Z + v242 * v68.k1
        local v254 = math.clamp((math.sqrt(v252 * v252 + v253 * v253) / v238 - 0.3) / 0.4, 0, 1)
        local v255 = v250 * (1 - 0.7 * v254)
        local v256 = (1 - v250) * (0.3 + 0.7 * v254)
        v250 = v255 / math.max(v255 + v256, 1e-6)
        if v254 > 0.5 then
            v251 = math.atan2(v253, v252)
        end
    end
    local v257 = (v237.k105 + v68.k41 * 0.5) / (v237.k65 + v68.k41 * 0.5 + v68.k46)
    local v258 = v237.k93 or v245
    local v259 = math.min(v68.k18, v223 - v221[1].k106)
    local v260, v261 = 0, 0
    for _, v262 in v217.k107 do
        if v262.k106 + 0.06 <= v223 and v68.k112(v217, v262.k106 + 0.06, 0.05).Y > 8 then
            v260 += 1
            if v262.k91 then
                v261 += 1
            end
        end
    end
    local v263 = v259 > 0.5 and v260 / v259 or 0
    local v264 = math.clamp((v261 + v68.k38) / (#v217.k74 + 1), 0, 0.95)
    local v265 = v217.k70 or 50
    local v266 = v230 or (v228 and -math.huge or v224.Y)
    local v267 = v68.k40
    local v268 = v219 and v235 + 1.6 or v235 + v267
    local v269 = {}
    local v270 = {}
    local v271 = v68.k3
    for v272 = 1, v68.k9 do
        local v273, v274 = v224.X, v224.Z
        local v275, v276 = v225, v226
        local v277, v278, v279, v280
        local v281
        local v282 = v258
        if v237.k103 == "move" then
            v277, v278, v279 = true, v245, v246
            v281 = v165(v237.k79, v68.k34, 0.25, v237.k63)
        elseif v237.k103 == "low" then
            if math.random() < v250 then
                v277 = false
                v281 = v165(v237.k104, v68.k35, 0.15, v237.k63)
            else
                local v283 = v161(v237.k110)
                if math.abs(v283) < 1.6 then
                    v283 = math.pi
                end
                v277, v278, v279 = true, v251 or v258 + v283, v238
                v282 = v278
                v281 = v155(v237.k79, v68.k34, 0.25)
            end
        else
            v277 = false
            v280 = v243 < v237.k108
            v281 = v165(v237.k104, v68.k35, 0.15, v237.k63)
        end
        local v284 = 0
        local v285
        local v286 = v237.k75
        local function v287()
            local v288 = math.abs(v161(v237.k110))
            local v289
            if v286 and v288 < 2.8 then
                v289 = math.random() < v237.k54 and -v286 or v286
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
                        v281 = v155(v237.k104, v68.k35, 0.15)
                    else
                        v278 += v287()
                        v281 = v155(v237.k79, v68.k34, 0.25)
                    end
                else
                    v277 = true
                    v280 = false
                    v278 = v282 + v161(v237.k102)
                    v279 = v238
                    v281 = v155(v237.k79, v68.k34, 0.25)
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
        local v304, v305, v306 = v190(v269, v218, v68.k20)
        local v307, v308, v309 = 0, 0, 0
        for v310 = 1, #v269 do
            local v311, v312 = v269[v310][1] - v304, v269[v310][2] - v305
            if v311 * v311 + v312 * v312 <= v68.k20 ^ 2 then
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
        local v314, v315, v316 = v171(v269, v68.k12)
        local v317, v318 = 0, 0
        for v319 = 1, #v269 do
            local v320, v321 = v269[v319][1] - v314, v269[v319][2] - v315
            if v320 * v320 + v321 * v321 <= v68.k12 ^ 2 then
                v317 += v269[v319][3]
                v318 += 1
            end
        end
        return Vector3.new(v314, (v318 > 0 and v317 / v318 or v224.Y) + v231, v315), v303, v316
    end
end

function v68.k90(v322, v323, v324)
    if v322 then
        return v323 >= v68.k22 or v324 >= v68.k19
    end
    return v323 >= v68.k14 or v324 >= v68.k11
end

function v68.k80()
    local v325 = { k98 = {}, k100 = 0 }
    local v326 = 0
    local v327 = v68.k29
    while v327 <= v68.k28 + 1e-9 do
        v326 += 1
        local v328 = (v327 - v68.k30) / v68.k31
        v325.k98[v326] = -0.5 * v328 * v328
        v327 += v68.k32
    end
    return v325
end

function v68.k82(v329, v330, v331, v332, v333, v334, v335, v336)
    local v337 = v330.k76
    if #v337 < 2 then
        return false
    end
    local v338 = v337[#v337].k106
    local v339 = v334 - v333
    local v340, v341 = v339.X, v339.Z
    local v342 = math.sqrt(v340 * v340 + v341 * v341)
    if v342 < 0.5 then
        return false
    end
    v340, v341 = v340 / v342, v341 / v342
    local v343 = v68.k20 + 0.2
    local v344 = {}
    local v345 = 0
    local v346 = v68.k29
    while v346 <= v68.k28 + 1e-9 do
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
            local v351 = v68.k57(v330, v350)
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
        v346 += v68.k32
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
        v329.k98[v359] += math.log(v360)
    end
    v329.k100 += 1
    return true
end

function v68.k81(v361, v362, v363, v364, v365, v366, v367)
    local v368 = v362.k76
    if #v368 < 2 then
        return false
    end
    local v369 = v368[#v368].k106
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
    local v377 = v68.k29
    while v377 <= v68.k28 + 1e-9 do
        v376 += 1
        local v378 = v363 + v364 + v377
        local v379 = v68.k57(v362, v378)
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
        v377 += v68.k32
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
        v361.k98[v392] += math.log(v393)
    end
    v361.k100 += 1
    return true
end

function v68.k84(v394)
    if v394.k100 < v68.k24 then
        return nil
    end
    local v395, v396 = 1, -math.huge
    for v397, v398 in v394.k98 do
        if v398 > v396 then
            v395, v396 = v397, v398
        end
    end
    return v68.k29 + (v395 - 1) * v68.k32
end

function v68.k55(v399)
    local v400 = v68.k84(v399)
    if v400 then
        v68.k16 = math.clamp(v400 - v68.k37, v68.k29, v68.k28)
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
        v68.k10 = v7.Gravity
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
local v419 = { k71 = nil, k109 = nil, k94 = nil, k58 = nil }
local v420
local v421 = {}
local v422
local v423

local v424 = 3
local v425 = v9.__c50
if type(v425) ~= "table" or v9.__c51 ~= game.JobId or v9.__c52 ~= v424 then
    v425 = v68.k80()
    v9.__c50, v9.__c51, v9.__c52 = v425, game.JobId, v424
end
local function v426()
    v68.k55(v425)
end
v426()

local function v427(v428)
    return (v428 == "Gun" and v15.k15) or (v428 == "Knife" and v15.k23)
end

local function v429()
    local v430 = v8.Character
    local v431 = v430 and v430:FindFirstChildOfClass("Tool")
    if v431 == v419.k109 and (not v431 or v419.k94 and v419.k94.Parent) then
        return
    end
    v419.k109, v419.k71, v419.k94 = v431, nil, nil
    if v431 then
        if v28(v431) then
            local v432 = v431:FindFirstChild("Events")
            v419.k71 = "Knife"
            v419.k94 = v432 and v432:FindFirstChild("KnifeThrown")
        elseif v25(v431) then
            v419.k71 = "Gun"
            v419.k94 = v431:FindFirstChild("Shoot")
        end
    end
    local v433 = v430 and v430:FindFirstChild("HumanoidRootPart")
    v419.k58 = v433 and v433:FindFirstChild("GunRaycastAttachment")
end

local function v434(v435, v436)
    if typeof(v436) == "CFrame" then
        return v436.Position
    end
    if v435 == "Gun" and v419.k58 then
        return v419.k58.WorldPosition
    end
    local v437 = v419.k109 and v419.k109:FindFirstChild("Handle")
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
                    local v466 = { k87 = v456, k95 = v457, k60 = v458, k83 = math.clamp(v464 / v449, 0, 2), k88 = v465 }
                    if v459 == "Murderer" then
                        v453 = v466
                    end
                    table.insert(v421, v466)
                    local v467 = v464 + v463 * 3
                    if v445 == "Knife" and v465 then
                        v467 -= 120
                    end
                    if v420 and v420.k87 == v456 then
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
    if not v483 or not v483.k95.Parent then
        return nil
    end
    local v486 = v418[v483.k87]
    if not v486 or v486.k95 ~= v483.k95 or #v486.k76 < 2 then
        return nil
    end
    local v487, _, v488, v489 = v68.k53(v486, v485, v484 == "Knife" and v401 or nil, v404)
    if not v487 then
        return nil
    end
    local v490 = v486.k76[#v486.k76].k86
    local v491 = v487 - v490
    if v491.Magnitude > 0.5 then
        local v492 = v411(v7, v490, v491, v412)
        if v492 and v492.Instance.CanCollide then
            v487 = v492.Position - v491.Unit * 1.5
        end
    end
    local function v493(v494)
        return v468(v485, v494, v483.k60, v484 == "Gun" and v477(v485, v494, v489) or nil)
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
                local v511 = v509 - 0.05 * v507.k83 + (v507.k88 and 0.08 or 0)
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
    local v529 = v526 and v418[v526.k87]
    if not v529 then
        return
    end
    local v530 = { k71 = v525, k106 = os.clock(), k96 = v404, k85 = v527, k53 = v528, k92 = v529, k60 = v526.k60, k109 = v419.k109 }
    if v525 == "Gun" then
        v423 = v530
        return
    end
    task.delay(1.9, function()
        if v10 then
            return
        end
        local v531 = v529.k62
        local v532 = v531 ~= nil and v531 >= v530.k106 and v531 <= v530.k106 + 1.7
        if v68.k82(v425, v529, v530.k106, v530.k96, v530.k85, v530.k53, v401, v532) then
            v426()
        end
    end)
end

local function v533(v534, v535, v536, v537)
    local v538 = v423
    if not v538 or v534 ~= v538.k109 or typeof(v536) ~= "Vector3" or os.clock() - v538.k106 > 1.5 then
        return
    end
    v423 = nil
    local v539 = v538.k85
    if typeof(v535) == "Vector3" then
        v539 = v535
    elseif typeof(v535) == "Instance" then
        if v535:IsA("Attachment") then
            v539 = v535.WorldPosition
        elseif v535:IsA("BasePart") then
            v539 = v535.Position
        end
    end
    local v540 = typeof(v537) == "Instance" and v538.k60 ~= nil and v537:IsDescendantOf(v538.k60)
    task.delay(1.1, function()
        if v10 then
            return
        end
        if v68.k81(v425, v538.k92, v538.k106, v538.k96, v539, v536, v540) then
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

local v544 = 4
local function v545(v546, v547, v548)
    local v549 = Vector3.new(v547.X - v546.X, 0, v547.Z - v546.Z)
    local v550 = v549.Magnitude
    local v551 = math.min(v548, v550 - v544)
    if v550 < 0.5 or v551 <= 0 then
        return v546
    end
    local v552 = v549 / v550
    local v553 = v411(v7, v546, v552 * (v551 + 1.5), v412)
    if v553 and v553.Instance.Transparency < 1 then
        v551 = math.min(v551, (v553.Position - v546).Magnitude - 1.5)
    end
    if v551 <= 0 then
        return v546
    end
    return v546 + v552 * v551
end

local function v554(v555, v556)
    if v427("Knife") then
        local v557, _, v558 = v499("Knife", v555)
        if v557 then
            return CFrame.new(v557), v558
        end
    end
    return v556, nil
end

local v559 = false
local function v560(v561, v562, v563, v564, v565, v566)
    local v567 = v8.Character
    local v568 = v567 and v567:FindFirstChild("HumanoidRootPart")
    local v569 = v419.k109 and v419.k109:FindFirstChild("Handle")
    local v570 = v564 - v563
    v570 = Vector3.new(v570.X, 0, v570.Z)
    if v559 or not (v568 and v569) or v570.Magnitude < 0.2 then
        v562[2] = v566
        pcall(v520, v561, v562)
        v524("Knife", v565, v563, v566.Position)
        return
    end
    v559 = true
    local v571 = false
    local v572 = v5:GetInstanceAddedSignal("ThrowingKnife"):Connect(function()
        v571 = true
    end)
    v568.CFrame += v570
    v2.Heartbeat:Wait()
    v2.Heartbeat:Wait()
    local v573 = v569.Position
    v562[1] = v569.CFrame
    local v574, v575 = v554(v573, v566)
    v562[2] = v574
    pcall(v520, v561, v562)
    v524("Knife", v575 or v565, v573, v574.Position)
    local v576 = os.clock()
    while not v571 and not v10 and os.clock() - v576 < 1 do
        v2.PreSimulation:Wait()
    end
    v572:Disconnect()
    if v568.Parent then
        v568.CFrame -= v570
    end
    v559 = false
end

local function v577(v578, v579, v580)
    local v581 = v434("Knife", v579[1])
    local v582, v583 = v554(v581, v579[2])
    v583 = v583 or v580
    if not (v15.k47 and v581 and typeof(v582) == "CFrame") then
        v579[2] = v582
        v520(v578, v579)
        if v581 and typeof(v582) == "CFrame" then
            v524("Knife", v583, v581, v582.Position)
        end
        return
    end
    local v584 = v545(v581, v582.Position, v15.k5)
    if v15.k6 == "Change" then
        task.spawn(v560, v578, v579, v581, v584, v583, v582)
        return
    end
    local v585 = typeof(v579[1]) == "CFrame" and (v579[1] - v579[1].Position) or CFrame.new()
    v579[1] = CFrame.new(v584) * v585
    local v586, v587 = v554(v584, v582)
    v579[2] = v586
    v520(v578, v579)
    v524("Knife", v587 or v583, v584, v586.Position)
end

local function v588(v589)
    v422 = nil
    if v589.k71 == "Knife" then
        pcall(v577, v589.k94, v589.k56, v589.k64)
        return
    end
    local v590 = v589.k56
    if v589.k71 == "Gun" and v419.k58 and typeof(v590[1]) == "CFrame" then
        v590[1] = v419.k58.WorldCFrame
    end
    local v591 = v434(v589.k71, v590[1]) or v589.k85
    local v592, _, v593, v594 = v499(v589.k71, v591)
    if v592 then
        v590[2] = v515(v589.k71, v591, v592, v594)
    elseif v589.k53 then
        v590[2] = v589.k53
    end
    if pcall(v520, v589.k94, v590) and typeof(v590[2]) == "CFrame" then
        v524(v589.k71, v593 or v589.k64, v591, v590[2].Position)
    end
end

local v595 = 0
v12(v2.PreSimulation:Connect(function()
    if v10 then
        return
    end
    if not (v15.k15 or v15.k23) then
        if next(v418) then
            table.clear(v418)
        end
        v420 = nil
        table.clear(v421)
        if v422 then
            v588(v422)
        end
        return
    end
    local v596 = os.clock()
    for _, v597 in v1:GetPlayers() do
        if v597 ~= v8 then
            local v598 = v597.Character
            local v599 = v598 and v598:FindFirstChild("HumanoidRootPart")
            local v600 = v598 and v598:FindFirstChildOfClass("Humanoid")
            if v599 and v600 then
                local v601 = v418[v597]
                if not v601 or v601.k95 ~= v599 then
                    v601 = v68.new()
                    v601.k95 = v599
                    v418[v597] = v601
                end
                if v600.Health <= 0 then
                    v601.k62 = v601.k62 or v596
                end
                if v600.UseJumpPower then
                    v601.k70 = v600.JumpPower
                else
                    v601.k70 = math.sqrt(2 * v7.Gravity * v600.JumpHeight)
                end
                if not v601.k62 or v596 - v601.k62 < 0.6 then
                    local v602 = v600:GetState()
                    local v603 = v600.FloorMaterial ~= Enum.Material.Air
                        or (v602 ~= Enum.HumanoidStateType.Freefall and v602 ~= Enum.HumanoidStateType.Jumping)
                    v68.k89(v601, v596, v599.Position, v603)
                end
            else
                v418[v597] = nil
            end
        end
    end
    v595 += 1
    if v595 % 60 == 0 then
        v414()
    end
    v429()
    if v419.k71 and v427(v419.k71) then
        v420 = v444(v419.k71)
    else
        v420 = nil
        table.clear(v421)
    end
    local v604 = v422
    if v604 then
        if v604.k94 ~= v419.k94 or not v420 then
            v588(v604)
        else
            local v605 = v434(v604.k71, v419.k58 and v419.k58.WorldCFrame) or v604.k85
            local _, v606 = v499(v604.k71, v605)
            if not v606 or v68.k90(v604.k71 == "Knife", v606, v596 - v604.k101) then
                v588(v604)
            end
        end
    end
end))
v12(v1.PlayerRemoving:Connect(function(v607)
    v418[v607] = nil
end))

local function v608(v609, v610)
    local v611 = v419.k71
    local v612 = v434(v611, v610[1])
    if not v612 then
        return false
    end
    local v613, v614, v615, v616 = v499(v611, v612)
    if not v613 then
        return false
    end
    local v617 = v515(v611, v612, v613, v616)
    if not v68.k90(v611 == "Knife", v614, 0) then
        if v422 then
            v588(v422)
        end
        v422 = { k94 = v609, k56 = v610, k71 = v611, k85 = v612, k53 = v617, k64 = v615, k101 = os.clock() }
        return true
    end
    if v611 == "Knife" then
        v577(v609, v610, v615)
        return true
    end
    v610[2] = v617
    v520(v609, v610)
    v524(v611, v615, v612, v617.Position)
    return true
end

local v618 = false
if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local v619
    local v620 = typeof(checkcaller) == "function" and checkcaller or function()
        return false
    end
    local function v621(self, ...)
        if v10 or self ~= v419.k94 then
            return v619(self, ...)
        end
        if getnamecallmethod() ~= "FireServer" or v620() then
            return v619(self, ...)
        end
        if not v427(v419.k71) then
            if v419.k71 == "Knife" and v15.k47 then
                local v622 = pcall(v577, self, table.pack(...))
                if v622 then
                    return nil
                end
            end
            return v619(self, ...)
        end
        local v623 = table.pack(...)
        local v624, v625 = pcall(v608, self, table.pack(...))
        if v624 and v625 then
            return nil
        end
        return v520(self, v623)
    end
    if typeof(newcclosure) == "function" then
        v621 = newcclosure(v621)
    end
    v619 = hookmetamethod(game, "__namecall", v621)
    v618 = true
end

local v626
pcall(function()
    v626 = require(v3:WaitForChild("ClientServices", 5):WaitForChild("WeaponService", 5))
end)
local v627, v628
if not v618 and type(v626) == "table" then
    v627, v628 = v626.GetMouseTargetCFrame, v626.GetTargetPosition
    local function v629()
        local v630 = v419.k71
        if v10 or not v630 or not v427(v630) then
            return nil
        end
        local v631 = v434(v630)
        if not v631 then
            return nil
        end
        local v632, _, _, v633 = v499(v630, v631)
        return v632 and v515(v630, v631, v632, v633)
    end
    v626.GetMouseTargetCFrame = function(self, ...)
        local v634, v635 = pcall(v629)
        if v634 and v635 then
            return v635
        end
        return v627(self, ...)
    end
    v626.GetTargetPosition = function(self, v636, v637, ...)
        v58, v59 = Vector2.new(v636, v637), os.clock()
        local v638, v639 = pcall(v629)
        if v638 and v639 then
            return v639
        end
        return v628(self, v636, v637, ...)
    end
end

local v640 = Instance.new("Folder")
v640.Name = "\0"
v640.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
local v641 = {}
local v642 = {
    Murderer = Color3.fromRGB(255, 50, 50),
    Sheriff = Color3.fromRGB(50, 140, 255),
    Hero = Color3.fromRGB(50, 140, 255),
    Innocent = Color3.fromRGB(60, 230, 90),
}
local function v643(v644)
    local v645 = v641[v644]
    if v645 then
        v645.k69:Destroy()
        v645.k59:Destroy()
        v641[v644] = nil
    end
end
v12(v1.PlayerRemoving:Connect(v643))
local function v646()
    for _, v647 in v1:GetPlayers() do
        if v647 ~= v8 then
            local v648, _, v649 = v41(v647)
            local v650, v651 = v35(v647)
            if v15.k7 and v648 and not v651 then
                local v652 = v642[v650] or v642.Innocent
                local v653 = v641[v647]
                if not v653 or v653.k60 ~= v649 then
                    v643(v647)
                    local v654 = Instance.new("Highlight")
                    v654.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    v654.FillTransparency = 0.55
                    v654.OutlineTransparency = 0
                    v654.Adornee = v649
                    v654.Parent = v640
                    local v655 = Instance.new("BillboardGui")
                    v655.AlwaysOnTop = true
                    v655.Size = UDim2.fromOffset(160, 22)
                    v655.StudsOffset = Vector3.new(0, 3.4, 0)
                    v655.Adornee = v648
                    v655.Parent = v640
                    local v656 = Instance.new("TextLabel")
                    v656.BackgroundTransparency = 1
                    v656.Size = UDim2.fromScale(1, 1)
                    v656.Font = Enum.Font.GothamBold
                    v656.TextSize = 13
                    v656.TextStrokeTransparency = 0.4
                    v656.Text = v647.DisplayName
                    v656.Parent = v655
                    v653 = { k69 = v654, k59 = v655, k72 = v656, k60 = v649 }
                    v641[v647] = v653
                end
                if v653.k61 ~= v652 then
                    v653.k61 = v652
                    v653.k69.FillColor = v652
                    v653.k69.OutlineColor = v652
                    v653.k72.TextColor3 = v652
                end
            else
                v643(v647)
            end
        end
    end
end
task.spawn(function()
    while not v10 do
        pcall(v646)
        task.wait(0.25)
    end
end)

local v657 = {}
local v658 = {}
local v659
local function v660(v661)
    local v662 = v658[v661]
    if v662 then
        return v662
    end
    local v663 = {}
    for _, v664 in v661:GetDescendants() do
        if v664:IsA("BasePart") then
            table.insert(v663, v664)
        end
    end
    v658[v661] = v663
    local v665
    v665 = v661.DescendantAdded:Connect(function(v666)
        if v666:IsA("BasePart") then
            table.insert(v663, v666)
        end
    end)
    v661.AncestryChanged:Once(function()
        v658[v661] = nil
        v665:Disconnect()
    end)
    return v663
end
v12(v2.PreSimulation:Connect(function()
    if not v15.k4 then
        v659 = nil
        return
    end
    local v667, v668 = v41(v8)
    local v669 = os.clock()
    for _, v670 in v1:GetPlayers() do
        if v670 ~= v8 then
            local v671 = v670.Character
            local v672 = v671 and v671:FindFirstChild("HumanoidRootPart")
            if v672 and v667 then
                local v673 = v672.Position - v667.Position
                if v673.X * v673.X + v673.Y * v673.Y + v673.Z * v673.Z < 3600 then
                    local v674 = v672.AssemblyAngularVelocity
                    local v675 = v672.AssemblyLinearVelocity
                    if v674:Dot(v674) > 625 or v675:Dot(v675) > 14400 then
                        v657[v670] = v669 + 3
                    end
                end
            end
            local v676 = v657[v670]
            if v676 then
                if v669 > v676 or not v671 then
                    v657[v670] = nil
                else
                    for _, v677 in v660(v671) do
                        if v677.CanCollide then
                            v677.CanCollide = false
                        end
                    end
                end
            end
        end
    end
    if not v667 then
        v659 = nil
        return
    end
    local v678 = v667.AssemblyLinearVelocity
    local v679 = math.sqrt(v678.X * v678.X + v678.Z * v678.Z)
    local v680 = v667.AssemblyAngularVelocity.Magnitude
    local v681 = v668.WalkSpeed
    if (v679 > math.max(v681 * 5, 90) or v678.Y > 140 or v680 > 35) and v659 then
        v667.AssemblyLinearVelocity = Vector3.zero
        v667.AssemblyAngularVelocity = Vector3.zero
        v667.CFrame = v659
    elseif v679 < v681 * 2 + 4 and v680 < 8 and math.abs(v678.Y) < 60 then
        v659 = v667.CFrame
    end
end))

local v682 = v14:CreateWindow({
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

local v683 = "\u{200B}\u{200C}\u{200B}"
pcall(function()
    v682:EditOpenButton({
        Title = v683,
        Icon = "",
        Transparency = 1,
        StrokeThickness = 0,
    })
end)
local v684 = {}
local function v685()
    local v686 = { game:GetService("CoreGui") }
    if typeof(gethui) == "function" then
        table.insert(v686, gethui())
    end
    local v687 = v8:FindFirstChildOfClass("PlayerGui")
    if v687 then
        table.insert(v686, v687)
    end
    local v688 = false
    for _, v689 in v686 do
        local v690, v691 = pcall(v689.GetDescendants, v689)
        if v690 then
            for _, v692 in v691 do
                if (v692:IsA("TextLabel") or v692:IsA("TextButton")) and v692.Text == v683 then
                    local v693 = v692
                    local v694 = v692.Parent
                    while v694 and v694:IsA("GuiObject") and v694.AbsoluteSize.X * v694.AbsoluteSize.Y < 320 * 160 do
                        v693 = v694
                        v694 = v694.Parent
                    end
                    if v693:IsA("GuiObject") and not v684[v693] then
                        v684[v693] = true
                        v693.Visible = false
                        v12(v693:GetPropertyChangedSignal("Visible"):Connect(function()
                            if v693.Visible then
                                v693.Visible = false
                            end
                        end))
                    end
                    v688 = true
                end
            end
        end
    end
    return v688
end
task.spawn(function()
    for _, v695 in { 0.2, 0.5, 1, 2, 4, 8 } do
        task.wait(v695)
        if v10 then
            return
        end
        local v696, v697 = pcall(v685)
        if v696 and v697 then
            return
        end
    end
end)
local v698 = Enum.KeyCode.K
v12(v4.InputBegan:Connect(function(v699)
    if v699.KeyCode == v698 then
        task.delay(0.15, pcall, v685)
        task.delay(0.6, pcall, v685)
    end
end))

local v700 = v682:Tab({ Title = "Main", Icon = "crosshair" })
v700:Section({ Title = "Silent Aim" })
v700:Toggle({
    Title = "Gun Silent Aim",
    Default = false,
    Callback = function(v701)
        v15.k15 = v701
    end,
})
v700:Toggle({
    Title = "Murderer Silent Aim",
    Default = false,
    Callback = function(v702)
        v15.k23 = v702
    end,
})
v700:Section({ Title = "Knife Throw" })
v700:Toggle({
    Title = "Start Throw Closer",
    Default = false,
    Callback = function(v703)
        v15.k47 = v703
    end,
})
v700:DropDown({
    Title = "Closer Method",
    Option = { "Spoof", "Change" },
    Value = "Spoof",
    Callback = function(v704)
        if v704 == "Spoof" or v704 == "Change" then
            v15.k6 = v704
        end
    end,
})
v700:Slider({
    Title = "Closer By (studs)",
    Step = 1,
    Value = { Min = 1, Max = 40, Default = 8 },
    Callback = function(v705)
        if type(v705) == "number" then
            v15.k5 = v705
        end
    end,
})
v700:Section({ Title = "Other" })
v700:Toggle({
    Title = "ESP",
    Default = false,
    Callback = function(v706)
        v15.k7 = v706
    end,
})
v700:Toggle({
    Title = "Anti Fling",
    Default = false,
    Callback = function(v707)
        v15.k4 = v707
        if not v707 then
            table.clear(v657)
        end
    end,
})

local v708 = v682:Tab({ Title = "Settings", Icon = "settings" })
local v709 = v708:Keybind({
    Title = "Toggle UI",
    Callback = function(v710)
        local v711 = typeof(v710) == "EnumItem" and v710 or Enum.KeyCode[tostring(v710)]
        if v711 then
            v698 = v711
            pcall(v682.SetToggleKey, v682, v711)
        end
    end,
})
pcall(function()
    v709:SetValue("K")
end)

v9.__c49 = function()
    v10 = true
    if v422 then
        pcall(v588, v422)
    end
    for _, v712 in v11 do
        pcall(v712.Disconnect, v712)
    end
    for v713 in v641 do
        v643(v713)
    end
    v640:Destroy()
    if v627 and v626 then
        v626.GetMouseTargetCFrame = v627
        v626.GetTargetPosition = v628
    end
    pcall(v682.Close, v682)
end
