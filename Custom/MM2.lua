local v1 = game:GetService("Players")
local v2 = game:GetService("RunService")
local v3 = game:GetService("ReplicatedStorage")
local v4 = game:GetService("UserInputService")
local v5 = game:GetService("CollectionService")
local v6 = game:GetService("Stats")
local v7 = workspace
local v8 = v1.LocalPlayer

local v9 = (typeof(getgenv) == "function" and getgenv()) or _G
if v9.__c55 then
    pcall(v9.__c55)
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
    k26 = false,
    k7 = false,
    k4 = false,
    k53 = false,
    k6 = "Spoof",
    k5 = 8,
    k47 = false,
    k27 = 0,
    k46 = false,
    k17 = "Spoof",
    k16 = 8,
    k18 = 500,
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
    k54 = 3.0,
    k43 = 0.034,
    k8 = 0.067,
    k10 = 196.2,
    k19 = 0.06,
    k41 = 0.01,
    k9 = 80,
    k44 = 1 / 30,
    k31 = 2.0,
    k30 = 0.4,
    k50 = 0.7,
    k29 = 0.1,
    k37 = 0.12,
    k38 = 1.5,
    k39 = 0.8,
    k40 = 1.5,
    k45 = 0.5,
    k52 = 0.7,
    k49 = 3,
    k48 = 0.9,
    k20 = 0.2,
    k1 = 0.05,
    k2 = 40,
    k51 = 0.035,
    k3 = 0.05,
    k12 = 1.0,
    k21 = 3,
    k42 = 0.2,
    k23 = 1.2,
    k11 = 0.5,
    k14 = 0.95,
    k22 = 0,
    k25 = 0.75,
    k13 = 0.3,
    k24 = -0.5,
    k33 = -0.3,
    k32 = 0.4,
    k36 = 0.005,
    k34 = 0.07,
    k35 = 0.12,
    k28 = 2,
}

function v68.new()
    return { k83 = {}, k73 = nil, k74 = true, k116 = {}, k81 = {}, k77 = 50 }
end

function v68.k97(v69, v70, v71, v72)
    local v73 = v69.k83
    local v74 = #v73
    if v74 > 0 and v70 <= v73[v74].k115 then
        return
    end
    v73[v74 + 1] = { k115 = v70, k93 = v71 }
    v74 += 1
    if v72 then
        v69.k73 = v71.Y
    end
    if v69.k74 and not v72 then
        local v75 = v69.k80 ~= nil and v70 - v69.k80 < 0.2
        table.insert(v69.k116, { k115 = v70, k99 = v75 })
    elseif v72 and not v69.k74 then
        v69.k80 = v70
        table.insert(v69.k81, v70)
    end
    local v76 = v70 - v68.k21
    while v69.k116[1] and v69.k116[1].k115 < v76 do
        table.remove(v69.k116, 1)
    end
    while v69.k81[1] and v69.k81[1] < v76 do
        table.remove(v69.k81, 1)
    end
    v69.k74 = v72
    local v77 = v70 - v68.k54 - 0.2
    local v78 = 0
    while v78 < v74 - 2 and v73[v78 + 1].k115 < v77 do
        v78 += 1
    end
    if v78 > 0 then
        table.move(v73, v78 + 1, v74, 1)
        for v79 = v74 - v78 + 1, v74 do
            v73[v79] = nil
        end
    end
end

function v68.k63(v80, v81)
    local v82 = v80.k83
    local v83 = #v82
    if v81 >= v82[v83].k115 then
        return v82[v83].k93
    end
    if v81 <= v82[1].k115 then
        return v82[1].k93
    end
    local v84, v85 = 1, v83
    while v85 - v84 > 1 do
        local v86 = (v84 + v85) // 2
        if v82[v86].k115 <= v81 then
            v84 = v86
        else
            v85 = v86
        end
    end
    local v87, v88 = v82[v84], v82[v85]
    return v87.k93 + (v88.k93 - v87.k93) * ((v81 - v87.k115) / math.max(v88.k115 - v87.k115, 1e-6))
end

function v68.k122(v89, v90, v91)
    return (v68.k63(v89, v90) - v68.k63(v89, v90 - v91)) / v91
end

local function v92(v93)
    v93 = (v93 + math.pi) % (2 * math.pi)
    return v93 - math.pi
end

function v68.k72(v94, v95, v96)
    local v97, v98, v99, v100, v101, v102, v103 = 0, 0, 0, 0, 0, 0, 0
    for v104 = 0, 4 do
        local v105 = -v96 * v104 / 4
        local v106 = v68.k63(v94, v95 + v105)
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

function v68.k85(v108)
    local v109 = v108.k83
    local v110 = v109[#v109].k115
    local v111 = math.max(v109[1].k115 + v68.k43, v110 - v68.k54)
    local v112 = {}
    local v113 = v111
    while v113 <= v110 + 1e-6 do
        local v114 = v68.k122(v108, v113, v68.k43)
        v112[#v112 + 1] = { k115 = v113, k123 = v114.X, k124 = v114.Z, k105 = math.sqrt(v114.X * v114.X + v114.Z * v114.Z) }
        v113 += 1 / 60
    end
    local v115 = {}
    for _, v116 in v112 do
        if v116.k105 > v68.k31 then
            v115[#v115 + 1] = v116.k105
        end
    end
    table.sort(v115)
    local v117 = #v115 >= 6 and v115[math.max(1, math.floor(#v115 * 0.7))] or 16
    local v118 = math.max(v68.k31, v117 * v68.k30)
    local v119 = v68.k3
    local v120 = v119 * math.log(1 / v68.k30) + v68.k43 / 2
    local v121 = v119 * math.log(1 / (1 - v68.k30)) + v68.k43 / 2
    local v122 = {
        k86 = {}, k113 = {}, k119 = {}, k111 = {},
        k114 = 0, k108 = 0, k71 = 0,
        k120 = v117, k117 = v118,
    }
    local v123, v124, v125, v126, v127, v128
    local v129, v130, v131
    local v132 = {}
    local v133
    for _, v134 in v112 do
        local v135 = v134.k105 > v118
        local v136 = v135 and math.atan2(v134.k124, v134.k123) or nil
        if not v123 then
            v123 = v135 and "move" or "stop"
            v124, v125 = v134.k115, false
            if v135 then
                v126 = v136
                v127, v128 = math.cos(v136), math.sin(v136)
            end
        elseif v123 == "move" then
            if v135 then
                table.insert(v132, v134)
                local v137 = v92(v136 - v126)
                if math.abs(v137) > v68.k50 then
                    local v138 = math.abs(v137) / 2
                    local v139 = v134.k115
                    for _, v140 in v132 do
                        local v141 = v140.k123 * v127 + v140.k124 * v128
                        local v142 = math.abs(v140.k123 * v128 - v140.k124 * v127)
                        if math.atan2(v142, v141) >= v138 then
                            v139 = v140.k115
                            break
                        end
                    end
                    v139 -= v68.k51 + v68.k43 / 2
                    local v143 = v122.k119[#v122.k119]
                    if v133 and v143 and v139 - v133 < v68.k29 and (v143 > 0) == (v137 > 0) and math.abs(v143 + v137) <= math.pi + 0.3 then
                        if math.abs(v143) <= 1.6 and math.abs(v143 + v137) > 1.6 then
                            v122.k108 += 1
                        end
                        v122.k119[#v122.k119] = v143 + v137
                    else
                        if v125 then
                            table.insert(v122.k86, v139 - v124)
                        end
                        table.insert(v122.k119, v137)
                        v122.k71 += 1
                        if math.abs(v137) > 1.6 then
                            v122.k108 += 1
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
                v129 = v134.k115
                v130 = v134.k115 - v120
                v131 = v126
            end
        elseif v123 == "low" then
            if v135 then
                local v144 = v92(v136 - v131)
                if v134.k115 - v129 < v68.k37 then
                    if math.abs(v144) > v68.k50 then
                        local v145 = (v130 + v134.k115 - v121) / 2
                        if v125 then
                            table.insert(v122.k86, v145 - v124)
                        end
                        table.insert(v122.k119, v144)
                        v122.k71 += 1
                        if math.abs(v144) > 1.6 then
                            v122.k108 += 1
                        end
                        v124, v125 = v145, true
                    end
                else
                    local v146 = v134.k115 - v121
                    if v125 then
                        table.insert(v122.k86, v130 - v124)
                    end
                    table.insert(v122.k113, v146 - v130)
                    table.insert(v122.k111, v144)
                    v122.k114 += 1
                    v122.k71 += 1
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
                v124, v125 = v134.k115 - v121, false
                v126 = v136
                v127, v128 = math.cos(v136), math.sin(v136)
                v132 = {}
            end
        end
    end
    local v147, v148 = 0, 0
    for v149 = 2, #v122.k119 do
        local v150, v151 = v122.k119[v149 - 1], v122.k119[v149]
        if math.abs(v150) < 2.8 and math.abs(v151) < 2.8 then
            if (v150 > 0) == (v151 > 0) then
                v147 += 1
            else
                v148 += 1
            end
        end
    end
    v122.k60 = (v148 + 1) / (v148 + v147 + 2)
    local v152 = v122.k119[#v122.k119]
    v122.k82 = v152 and (v152 > 0 and 1 or -1) or nil
    v122.k112 = v123
    v122.k101 = v126
    if v123 == "move" then
        v122.k69 = v110 - v124
    elseif v123 == "low" then
        v122.k84 = v110 - v129
        v122.k69 = v110 - v130
        v122.k101 = v131
        if v122.k84 >= v68.k37 then
            v122.k112 = "stop"
        end
    else
        v122.k69 = v110 - v111
    end
    return v122
end

local function v153(v154)
    if v154 >= v68.k49 then
        return v68.k48
    end
    return v154 / (v154 + v68.k40)
end

local function v155(v156, v157, v158)
    local v159 = #v156
    if v159 > 0 and math.random() < v153(v159) then
        local v160 = math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
        return math.max(0.02, v156[math.random(1, v159)] * math.exp(v68.k20 * v160))
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

function v68.k59(v217, v218, v219, v220)
    local v221 = v217.k83
    local v222 = #v221
    if v222 == 0 then
        return nil
    end
    local v223 = v221[v222].k115
    local v224 = v221[v222].k93
    local v225, v226 = v68.k72(v217, v223, v68.k8)
    local v227 = v68.k122(v217, v223, 0.035).Y
    local v228 = math.abs(v227) > 6 or (not v217.k74 and v217.k73 ~= nil and v224.Y > v217.k73 + 0.5)
    local v229 = v68.k10
    local v230 = v217.k73
    local v231 = v219 and v68.k24 or v68.k13
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
    local v235 = math.max(0, v220 + v68.k19 + v68.k41)
    if v222 < 8 then
        local v236 = v235
        if v219 then
            v236 = v235 + (v224 - v218).Magnitude / v219
        end
        return Vector3.new(v224.X + v225 * v236, v232(v236), v224.Z + v226 * v236), v236, 1
    end
    local v237 = v68.k85(v217)
    local v238 = v237.k120
    local v239 = v68.k122(v217, v223, v68.k43)
    local v240 = v68.k122(v217, v223 - v68.k43, v68.k43)
    local v241, v242 = (v239.X - v240.X) / v68.k43, (v239.Z - v240.Z) / v68.k43
    local v243 = math.sqrt(v225 * v225 + v226 * v226)
    local v244 = v243 > 0.5 and (v241 * v225 + v242 * v226) / v243 or 0
    local v245 = math.atan2(v226, v225)
    local v246 = v243
    if v237.k112 == "move" then
        local v247, v248 = v239.X + v241 * v68.k1, v239.Z + v242 * v68.k1
        local v249 = math.sqrt(v247 * v247 + v248 * v248)
        if math.sqrt(v241 * v241 + v242 * v242) > v68.k2 and v249 > v237.k117 then
            v245 = math.atan2(v248, v247)
            if v243 < v238 * 0.85 and v249 > v243 then
                v246 = math.min(v249, v238)
            end
        end
        if v244 > v68.k2 and v243 < v238 * 0.85 then
            v246 = v238
        end
    end
    local v250 = (v237.k114 + v68.k45) / (v237.k114 + v237.k108 + v68.k45 + v68.k52)
    local v251
    if v237.k112 == "low" then
        local v252, v253 = v239.X + v241 * v68.k1, v239.Z + v242 * v68.k1
        local v254 = math.clamp((math.sqrt(v252 * v252 + v253 * v253) / v238 - 0.3) / 0.4, 0, 1)
        local v255 = v250 * (1 - 0.7 * v254)
        local v256 = (1 - v250) * (0.3 + 0.7 * v254)
        v250 = v255 / math.max(v255 + v256, 1e-6)
        if v254 > 0.5 then
            v251 = math.atan2(v253, v252)
        end
    end
    local v257 = (v237.k114 + v68.k45 * 0.5) / (v237.k71 + v68.k45 * 0.5 + v68.k52)
    local v258 = v237.k101 or v245
    local v259 = math.min(v68.k21, v223 - v221[1].k115)
    local v260, v261 = 0, 0
    for _, v262 in v217.k116 do
        if v262.k115 + 0.06 <= v223 and v68.k122(v217, v262.k115 + 0.06, 0.05).Y > 8 then
            v260 += 1
            if v262.k99 then
                v261 += 1
            end
        end
    end
    local v263 = v259 > 0.5 and v260 / v259 or 0
    local v264 = math.clamp((v261 + v68.k42) / (#v217.k81 + 1), 0, 0.95)
    local v265 = v217.k77 or 50
    local v266 = v230 or (v228 and -math.huge or v224.Y)
    local v267 = v68.k44
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
        if v237.k112 == "move" then
            v277, v278, v279 = true, v245, v246
            v281 = v165(v237.k86, v68.k38, 0.25, v237.k69)
        elseif v237.k112 == "low" then
            if math.random() < v250 then
                v277 = false
                v281 = v165(v237.k113, v68.k39, 0.15, v237.k69)
            else
                local v283 = v161(v237.k119)
                if math.abs(v283) < 1.6 then
                    v283 = math.pi
                end
                v277, v278, v279 = true, v251 or v258 + v283, v238
                v282 = v278
                v281 = v155(v237.k86, v68.k38, 0.25)
            end
        else
            v277 = false
            v280 = v243 < v237.k117
            v281 = v165(v237.k113, v68.k39, 0.15, v237.k69)
        end
        local v284 = 0
        local v285
        local v286 = v237.k82
        local function v287()
            local v288 = math.abs(v161(v237.k119))
            local v289
            if v286 and v288 < 2.8 then
                v289 = math.random() < v237.k60 and -v286 or v286
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
                        v281 = v155(v237.k113, v68.k39, 0.15)
                    else
                        v278 += v287()
                        v281 = v155(v237.k86, v68.k38, 0.25)
                    end
                else
                    v277 = true
                    v280 = false
                    v278 = v282 + v161(v237.k111)
                    v279 = v238
                    v281 = v155(v237.k86, v68.k38, 0.25)
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
        local v304, v305, v306 = v190(v269, v218, v68.k23)
        local v307, v308, v309 = 0, 0, 0
        for v310 = 1, #v269 do
            local v311, v312 = v269[v310][1] - v304, v269[v310][2] - v305
            if v311 * v311 + v312 * v312 <= v68.k23 ^ 2 then
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

function v68.k98(v322, v323, v324)
    if v322 then
        return v323 >= v68.k25 or v324 >= v68.k22
    end
    return v323 >= v68.k14 or v324 >= v68.k11
end

function v68.k87()
    local v325 = { k107 = {}, k109 = 0 }
    local v326 = 0
    local v327 = v68.k33
    while v327 <= v68.k32 + 1e-9 do
        v326 += 1
        local v328 = (v327 - v68.k34) / v68.k35
        v325.k107[v326] = -0.5 * v328 * v328
        v327 += v68.k36
    end
    return v325
end

function v68.k89(v329, v330, v331, v332, v333, v334, v335, v336)
    local v337 = v330.k83
    if #v337 < 2 then
        return false
    end
    local v338 = v337[#v337].k115
    local v339 = v334 - v333
    local v340, v341 = v339.X, v339.Z
    local v342 = math.sqrt(v340 * v340 + v341 * v341)
    if v342 < 0.5 then
        return false
    end
    v340, v341 = v340 / v342, v341 / v342
    local v343 = v68.k23 + 0.2
    local v344 = {}
    local v345 = 0
    local v346 = v68.k33
    while v346 <= v68.k32 + 1e-9 do
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
            local v351 = v68.k63(v330, v350)
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
        v346 += v68.k36
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
        v329.k107[v359] += math.log(v360)
    end
    v329.k109 += 1
    return true
end

function v68.k88(v361, v362, v363, v364, v365, v366, v367)
    local v368 = v362.k83
    if #v368 < 2 then
        return false
    end
    local v369 = v368[#v368].k115
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
    local v377 = v68.k33
    while v377 <= v68.k32 + 1e-9 do
        v376 += 1
        local v378 = v363 + v364 + v377
        local v379 = v68.k63(v362, v378)
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
        v377 += v68.k36
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
        v361.k107[v392] += math.log(v393)
    end
    v361.k109 += 1
    return true
end

function v68.k91(v394)
    if v394.k109 < v68.k28 then
        return nil
    end
    local v395, v396 = 1, -math.huge
    for v397, v398 in v394.k107 do
        if v398 > v396 then
            v395, v396 = v397, v398
        end
    end
    return v68.k33 + (v395 - 1) * v68.k36
end

function v68.k61(v399)
    local v400 = v68.k91(v399)
    if v400 then
        v68.k19 = math.clamp(v400 - v68.k41, v68.k33, v68.k32)
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
local v419 = { k78 = nil, k118 = nil, k102 = nil, k64 = nil }
local v420
local v421 = {}
local v422
local v423

local v424 = 3
local v425 = v9.__c56
if type(v425) ~= "table" or v9.__c57 ~= game.JobId or v9.__c58 ~= v424 then
    v425 = v68.k87()
    v9.__c56, v9.__c57, v9.__c58 = v425, game.JobId, v424
end
local function v426()
    v68.k61(v425)
end
v426()

local function v427(v428)
    return (v428 == "Gun" and v15.k15) or (v428 == "Knife" and v15.k26)
end

local function v429()
    local v430 = v8.Character
    local v431 = v430 and v430:FindFirstChildOfClass("Tool")
    if v431 == v419.k118 and (not v431 or v419.k102 and v419.k102.Parent) then
        return
    end
    v419.k118, v419.k78, v419.k102 = v431, nil, nil
    if v431 then
        if v28(v431) then
            local v432 = v431:FindFirstChild("Events")
            v419.k78 = "Knife"
            v419.k102 = v432 and v432:FindFirstChild("KnifeThrown")
        elseif v25(v431) then
            v419.k78 = "Gun"
            v419.k102 = v431:FindFirstChild("Shoot")
        end
    end
    local v433 = v430 and v430:FindFirstChild("HumanoidRootPart")
    v419.k64 = v433 and v433:FindFirstChild("GunRaycastAttachment")
end

local function v434(v435, v436)
    if typeof(v436) == "CFrame" then
        return v436.Position
    end
    if v435 == "Gun" and v419.k64 then
        return v419.k64.WorldPosition
    end
    local v437 = v419.k118 and v419.k118:FindFirstChild("Handle")
    return v437 and v437.Position
end

local v438 = { k94 = setmetatable({}, { __mode = "k" }), k118 = nil, k106 = 0 }
local function v439()
    for v440, v441 in pairs(v438.k94) do
        pcall(debug.setupvalue, v440, v441.k76, v441.k121)
    end
    table.clear(v438.k94)
    v438.k118 = nil
end
local function v442()
    local v443 = v419.k78 == "Knife" and v419.k118 or nil
    local v444 = v443 and v443:GetAttribute("ThrowSpeed")
    if type(v444) ~= "number" or v444 <= 0.05 then
        return
    end
    if typeof(getgc) ~= "function" or type(debug.setupvalue) ~= "function" or type(debug.getupvalues) ~= "function" then
        return
    end
    local v445 = false
    for _, v446 in getgc() do
        if type(v446) == "function" and not v438.k94[v446] and debug.info(v446, "n") == "startThrowKnife" then
            local v447, v448 = pcall(debug.getupvalues, v446)
            if v447 and type(v448) == "table" then
                for v449, v450 in v448 do
                    if v450 == v444 then
                        if pcall(debug.setupvalue, v446, v449, 0.02) then
                            v438.k94[v446] = { k76 = v449, k121 = v444 }
                            v445 = true
                        end
                        break
                    end
                end
            end
        end
    end
    if v445 then
        v438.k118 = v443
    end
end
task.spawn(function()
    while not v10 do
        if v15.k47 then
            if v419.k78 == "Knife" and v419.k118 ~= v438.k118 and os.clock() - v438.k106 > 2 then
                v438.k106 = os.clock()
                pcall(v442)
            end
        elseif next(v438.k94) then
            v439()
        end
        task.wait(0.5)
    end
end)

local function v451(v452, v453)
    for _, v454 in { "HumanoidRootPart", "Head", "UpperTorso", "Torso", "LowerTorso", "LeftUpperLeg", "RightUpperLeg" } do
        local v455 = v453:FindFirstChild(v454)
        if v455 then
            local v456 = v411(v7, v452, v455.Position - v452, v412)
            if not v456 then
                return true
            end
            if v456.Instance.Transparency >= 1 and v50(v452, v455.Position, v453) then
                return true
            end
        end
    end
    return false
end

local function v457(v458)
    table.clear(v421)
    local v459 = v41(v8)
    if not v459 then
        return nil
    end
    local v460 = v7.CurrentCamera
    local v461 = v65()
    local v462 = math.max(v460.ViewportSize.Magnitude, 1)
    local v463 = v8.Character:FindFirstChild("Head")
    local v464 = v434(v458) or (v463 and v463.Position) or v459.Position
    local v465, v466, v467, v468 = false, nil, nil, nil
    for _, v469 in v1:GetPlayers() do
        if v469 ~= v8 then
            local v470, _, v471 = v41(v469)
            local v472, v473 = v35(v469)
            if v470 and not v473 then
                if v472 == "Murderer" then
                    v465 = true
                end
                if v451(v464, v471) then
                    local v474, v475 = v460:WorldToViewportPoint(v470.Position)
                    local v476 = (v470.Position - v459.Position).Magnitude
                    local v477
                    if v475 and v474.Z > 0 then
                        v477 = (Vector2.new(v474.X, v474.Y) - v461).Magnitude
                    else
                        v477 = v462 + v476
                    end
                    local v478 = v472 == "Sheriff" or v472 == "Hero"
                    local v479 = { k95 = v469, k103 = v470, k66 = v471, k90 = math.clamp(v477 / v462, 0, 2), k96 = v478 }
                    if v472 == "Murderer" then
                        v466 = v479
                    end
                    table.insert(v421, v479)
                    local v480 = v477 + v476 * 3
                    if v458 == "Knife" and v478 then
                        v480 -= 120
                    end
                    if v420 and v420.k95 == v469 then
                        v480 -= 40
                    end
                    if not v468 or v480 < v468 then
                        v467, v468 = v479, v480
                    end
                end
            end
        end
    end
    if v458 == "Gun" and v465 then
        table.clear(v421)
        if v466 then
            table.insert(v421, v466)
        end
        return v466
    end
    return v467
end

local function v481(v482, v483, v484, v485)
    local v486 = v411(v7, v482, v483 - v482, v412)
    if v486 and v486.Instance.Transparency < 1 then
        return false
    end
    if v484 then
        local v487 = v485 or v483
        local v488 = v411(v7, v482, v487 - v482, v413)
        if v488 and not v488.Instance:IsDescendantOf(v484) then
            local v489 = v488.Instance:FindFirstAncestorOfClass("Model")
            if v489 and v489:FindFirstChildOfClass("Humanoid") and v1:GetPlayerFromCharacter(v489) then
                return false
            end
        end
    end
    return true
end
local function v490(v491, v492, v493)
    local v494 = v492 - v491
    if v494.Magnitude < 0.1 then
        return v492
    end
    return v492 + v494.Unit * math.clamp((v493 or 0) + 2, 4, 10)
end

local function v495(v496, v497, v498)
    if not v496 or not v496.k103.Parent then
        return nil
    end
    local v499 = v418[v496.k95]
    if not v499 or v499.k103 ~= v496.k103 or #v499.k83 < 2 then
        return nil
    end
    local v500, _, v501, v502 = v68.k59(v499, v498, v497 == "Knife" and v401 or nil, v404)
    if not v500 then
        return nil
    end
    local v503 = v499.k83[#v499.k83].k93
    local v504 = v500 - v503
    if v504.Magnitude > 0.5 then
        local v505 = v411(v7, v503, v504, v412)
        if v505 and v505.Instance.CanCollide then
            v500 = v505.Position - v504.Unit * 1.5
        end
    end
    local function v506(v507)
        return v481(v498, v507, v496.k66, v497 == "Gun" and v490(v498, v507, v502) or nil)
    end
    if not v506(v500) then
        local v508 = v500 - v498
        local v509 = Vector3.new(-v508.Z, 0, v508.X)
        v509 = v509.Magnitude > 0.01 and v509.Unit or Vector3.new(1, 0, 0)
        for _, v510 in {
            Vector3.new(0, 0.8, 0), Vector3.new(0, 1.6, 0), Vector3.new(0, -1.0, 0), Vector3.new(0, -2.0, 0),
            v509 * 0.7, -v509 * 0.7, v509 * 0.6 + Vector3.new(0, 0.8, 0), -v509 * 0.6 + Vector3.new(0, 0.8, 0),
            v509 * 0.6 - Vector3.new(0, 1.0, 0), -v509 * 0.6 - Vector3.new(0, 1.0, 0),
        } do
            local v511 = v500 + v510
            if v506(v511) then
                v500 = v511
                break
            end
        end
    end
    return v500, v501, v502
end

local function v512(v513, v514)
    if v513 == "Knife" and #v421 > 1 then
        local v515, v516, v517, v518, v519
        for _, v520 in v421 do
            local v521, v522, v523 = v495(v520, v513, v514)
            if v521 then
                local v524 = v522 - 0.05 * v520.k90 + (v520.k96 and 0.08 or 0)
                if not v518 or v524 > v518 then
                    v515, v516, v517, v518, v519 = v520, v521, v522, v524, v523
                end
            end
        end
        if v515 then
            return v516, v517, v515, v519
        end
    end
    local v525, v526, v527 = v495(v420, v513, v514)
    return v525, v526, v420, v527
end

local function v528(v529, v530, v531, v532)
    if v529 == "Gun" then
        return CFrame.new(v490(v530, v531, v532))
    end
    return CFrame.new(v531)
end

local function v533(v534, v535)
    local v536 = v534.FireServer
    return v536(v534, table.unpack(v535, 1, v535.n))
end

local function v537(v538, v539, v540, v541)
    local v542 = v539 and v418[v539.k95]
    if not v542 then
        return
    end
    local v543 = { k78 = v538, k115 = os.clock(), k104 = v404, k92 = v540, k59 = v541, k100 = v542, k66 = v539.k66, k118 = v419.k118 }
    if v538 == "Gun" then
        v423 = v543
        return
    end
    task.delay(1.9, function()
        if v10 then
            return
        end
        local v544 = v542.k68
        local v545 = v544 ~= nil and v544 >= v543.k115 and v544 <= v543.k115 + 1.7
        if v68.k89(v425, v542, v543.k115, v543.k104, v543.k92, v543.k59, v401, v545) then
            v426()
        end
    end)
end

local v546 = 0
local function v547(v548, v549, v550, v551)
    local v552 = v423
    if not v552 or v548 ~= v552.k118 or typeof(v550) ~= "Vector3" or os.clock() - v552.k115 > 1.5 then
        return
    end
    v423 = nil
    local v553 = v552.k92
    if typeof(v549) == "Vector3" then
        v553 = v549
    elseif typeof(v549) == "Instance" then
        if v549:IsA("Attachment") then
            v553 = v549.WorldPosition
        elseif v549:IsA("BasePart") then
            v553 = v549.Position
        end
    end
    local v554 = typeof(v551) == "Instance" and v552.k66 ~= nil and v551:IsDescendantOf(v552.k66)
    task.delay(1.1, function()
        if v10 then
            return
        end
        if v68.k88(v425, v552.k100, v552.k115, v552.k104, v553, v550, v554) then
            v426()
        end
    end)
end
task.spawn(function()
    local v555 = v3:WaitForChild("ClientServices", 10)
    local v556 = v555 and v555:WaitForChild("WeaponService", 10)
    local v557 = v556 and v556:WaitForChild("GunFired", 10)
    if v557 and not v10 then
        v12(v557.OnClientEvent:Connect(function(...)
            v546 = os.clock()
            pcall(v547, ...)
        end))
    end
end)

local v558 = 4
local function v559(v560, v561, v562)
    local v563 = Vector3.new(v561.X - v560.X, 0, v561.Z - v560.Z)
    local v564 = v563.Magnitude
    local v565 = math.min(v562, v564 - v558)
    if v564 < 0.5 or v565 <= 0 then
        return v560
    end
    local v566 = v563 / v564
    local v567 = v411(v7, v560, v566 * (v565 + 1.5), v412)
    if v567 and v567.Instance.Transparency < 1 then
        v565 = math.min(v565, (v567.Position - v560).Magnitude - 1.5)
    end
    if v565 <= 0 then
        return v560
    end
    return v560 + v566 * v565
end

local function v568(v569)
    if v569 == "Knife" then
        return v15.k53
    elseif v569 == "Gun" then
        return v15.k46
    end
    return false
end

local function v570(v571)
    return v571 == "Knife" and v15.k6 or v15.k17
end

local function v572(v573)
    return v573 == "Knife" and v15.k5 or v15.k16
end

local function v574(v575, v576, v577)
    if v576 and v427(v575) then
        local v578, _, v579, v580 = v512(v575, v576)
        if v578 then
            return v528(v575, v576, v578, v580), v579, v578
        end
    end
    return v577, nil, typeof(v577) == "CFrame" and v577.Position or nil
end

local function v581(v582)
    if v582 == "Gun" then
        local v583 = v419.k64
        return v583 and v583.WorldCFrame
    end
    local v584 = v419.k118 and v419.k118:FindFirstChild("Handle")
    return v584 and v584.CFrame
end

local v585 = false
local function v586(v587, v588, v589, v590, v591, v592, v593)
    local v594 = v8.Character
    local v595 = v594 and v594:FindFirstChild("HumanoidRootPart")
    local v596 = v591 - v590
    v596 = Vector3.new(v596.X, 0, v596.Z)
    if v585 or not v595 or not v581(v587) or v596.Magnitude < 0.2 then
        v589[2] = v593
        pcall(v533, v588, v589)
        v537(v587, v592, v590, v593.Position)
        return
    end
    v585 = true
    local v597 = false
    local v598
    if v587 == "Knife" then
        v598 = v5:GetInstanceAddedSignal("ThrowingKnife"):Connect(function()
            v597 = true
        end)
    end
    v595.CFrame += v596
    v2.Heartbeat:Wait()
    v2.Heartbeat:Wait()
    local v599 = v581(v587) or (CFrame.new(v591) * (v589[1] - v589[1].Position))
    local v600 = v599.Position
    v589[1] = v599
    local v601, v602 = v574(v587, v600, v593)
    v589[2] = v601
    local v603 = os.clock()
    pcall(v533, v588, v589)
    v537(v587, v602 or v592, v600, v601.Position)
    while not v10 and os.clock() - v603 < 1 do
        if v597 or (v587 == "Gun" and v546 > v603) then
            break
        end
        v2.PreSimulation:Wait()
    end
    if v598 then
        v598:Disconnect()
    end
    if v595.Parent then
        v595.CFrame -= v596
    end
    v585 = false
end

local function v604(v605, v606, v607, v608, v609)
    if v605 == "Gun" and v419.k64 and typeof(v607[1]) == "CFrame" then
        v607[1] = v419.k64.WorldCFrame
    end
    local v610 = v434(v605, v607[1])
    local v611, v612, v613 = v574(v605, v610, v609 or v607[2])
    v612 = v612 or v608
    if not (v568(v605) and v610 and v613 and typeof(v611) == "CFrame" and typeof(v607[1]) == "CFrame") then
        v607[2] = v611
        v533(v606, v607)
        if v610 and typeof(v611) == "CFrame" then
            v537(v605, v612, v610, v611.Position)
        end
        return
    end
    local v614 = v559(v610, v613, v572(v605))
    if v570(v605) == "Change" then
        task.spawn(v586, v605, v606, v607, v610, v614, v612, v611)
        return
    end
    v607[1] = CFrame.new(v614) * (v607[1] - v607[1].Position)
    local v615, v616 = v574(v605, v614, v611)
    v607[2] = v615
    v533(v606, v607)
    v537(v605, v616 or v612, v614, v615.Position)
end

local function v617(v618)
    v422 = nil
    pcall(v604, v618.k78, v618.k102, v618.k62, v618.k70, v618.k59)
end

local v619 = 0
v12(v2.PreSimulation:Connect(function()
    if v10 then
        return
    end
    if not (v15.k15 or v15.k26) then
        if next(v418) then
            table.clear(v418)
        end
        v420 = nil
        table.clear(v421)
        if v422 then
            v617(v422)
        end
        return
    end
    local v620 = os.clock()
    for _, v621 in v1:GetPlayers() do
        if v621 ~= v8 then
            local v622 = v621.Character
            local v623 = v622 and v622:FindFirstChild("HumanoidRootPart")
            local v624 = v622 and v622:FindFirstChildOfClass("Humanoid")
            if v623 and v624 then
                local v625 = v418[v621]
                if not v625 or v625.k103 ~= v623 then
                    v625 = v68.new()
                    v625.k103 = v623
                    v418[v621] = v625
                end
                if v624.Health <= 0 then
                    v625.k68 = v625.k68 or v620
                end
                if v624.UseJumpPower then
                    v625.k77 = v624.JumpPower
                else
                    v625.k77 = math.sqrt(2 * v7.Gravity * v624.JumpHeight)
                end
                if not v625.k68 or v620 - v625.k68 < 0.6 then
                    local v626 = v624:GetState()
                    local v627 = v624.FloorMaterial ~= Enum.Material.Air
                        or (v626 ~= Enum.HumanoidStateType.Freefall and v626 ~= Enum.HumanoidStateType.Jumping)
                    v68.k97(v625, v620, v623.Position, v627)
                end
            else
                v418[v621] = nil
            end
        end
    end
    v619 += 1
    if v619 % 60 == 0 then
        v414()
    end
    v429()
    if v419.k78 and v427(v419.k78) then
        v420 = v457(v419.k78)
    else
        v420 = nil
        table.clear(v421)
    end
    local v628 = v422
    if v628 then
        if v628.k102 ~= v419.k102 or not v420 then
            v617(v628)
        else
            local v629 = v434(v628.k78, v419.k64 and v419.k64.WorldCFrame) or v628.k92
            local _, v630 = v512(v628.k78, v629)
            if not v630 or v68.k98(v628.k78 == "Knife", v630, v620 - v628.k110) then
                v617(v628)
            end
        end
    end
end))
v12(v1.PlayerRemoving:Connect(function(v631)
    v418[v631] = nil
end))

local function v632(v633, v634)
    local v635 = v419.k78
    local v636 = v434(v635, v634[1])
    if not v636 then
        return false
    end
    local v637, v638, v639, v640 = v512(v635, v636)
    if not v637 then
        return false
    end
    local v641 = v528(v635, v636, v637, v640)
    if not v68.k98(v635 == "Knife", v638, 0) then
        if v422 then
            v617(v422)
        end
        v422 = { k102 = v633, k62 = v634, k78 = v635, k92 = v636, k59 = v641, k70 = v639, k110 = os.clock() }
        return true
    end
    v604(v635, v633, v634, v639, v641)
    return true
end

local v642 = false
if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local v643
    local v644 = typeof(checkcaller) == "function" and checkcaller or function()
        return false
    end
    local function v645(self, ...)
        if v10 or self ~= v419.k102 then
            return v643(self, ...)
        end
        if getnamecallmethod() ~= "FireServer" or v644() then
            return v643(self, ...)
        end
        if not v427(v419.k78) then
            if v419.k78 and v568(v419.k78) then
                local v646 = pcall(v604, v419.k78, self, table.pack(...))
                if v646 then
                    return nil
                end
            end
            return v643(self, ...)
        end
        local v647 = table.pack(...)
        local v648, v649 = pcall(v632, self, table.pack(...))
        if v648 and v649 then
            return nil
        end
        return v533(self, v647)
    end
    if typeof(newcclosure) == "function" then
        v645 = newcclosure(v645)
    end
    v643 = hookmetamethod(game, "__namecall", v645)
    v642 = true
end

local v650
pcall(function()
    v650 = require(v3:WaitForChild("ClientServices", 5):WaitForChild("WeaponService", 5))
end)
local v651, v652
if not v642 and type(v650) == "table" then
    v651, v652 = v650.GetMouseTargetCFrame, v650.GetTargetPosition
    local function v653()
        local v654 = v419.k78
        if v10 or not v654 or not v427(v654) then
            return nil
        end
        local v655 = v434(v654)
        if not v655 then
            return nil
        end
        local v656, _, _, v657 = v512(v654, v655)
        return v656 and v528(v654, v655, v656, v657)
    end
    v650.GetMouseTargetCFrame = function(self, ...)
        local v658, v659 = pcall(v653)
        if v658 and v659 then
            return v659
        end
        return v651(self, ...)
    end
    v650.GetTargetPosition = function(self, v660, v661, ...)
        v58, v59 = Vector2.new(v660, v661), os.clock()
        local v662, v663 = pcall(v653)
        if v662 and v663 then
            return v663
        end
        return v652(self, v660, v661, ...)
    end
end

local v664 = Instance.new("Folder")
v664.Name = "\0"
v664.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
local v665 = {}
local v666 = {
    Murderer = Color3.fromRGB(255, 50, 50),
    Sheriff = Color3.fromRGB(50, 140, 255),
    Hero = Color3.fromRGB(50, 140, 255),
    Innocent = Color3.fromRGB(60, 230, 90),
}
local function v667(v668)
    local v669 = v665[v668]
    if v669 then
        v669.k75:Destroy()
        v669.k65:Destroy()
        v665[v668] = nil
    end
end
v12(v1.PlayerRemoving:Connect(v667))
local function v670()
    for _, v671 in v1:GetPlayers() do
        if v671 ~= v8 then
            local v672, _, v673 = v41(v671)
            local v674, v675 = v35(v671)
            if v15.k7 and v672 and not v675 then
                local v676 = v666[v674] or v666.Innocent
                local v677 = v665[v671]
                if not v677 or v677.k66 ~= v673 then
                    v667(v671)
                    local v678 = Instance.new("Highlight")
                    v678.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    v678.FillTransparency = 0.55
                    v678.OutlineTransparency = 0
                    v678.Adornee = v673
                    v678.Parent = v664
                    local v679 = Instance.new("BillboardGui")
                    v679.AlwaysOnTop = true
                    v679.Size = UDim2.fromOffset(160, 22)
                    v679.StudsOffset = Vector3.new(0, 3.4, 0)
                    v679.Adornee = v672
                    v679.Parent = v664
                    local v680 = Instance.new("TextLabel")
                    v680.BackgroundTransparency = 1
                    v680.Size = UDim2.fromScale(1, 1)
                    v680.Font = Enum.Font.GothamBold
                    v680.TextSize = 13
                    v680.TextStrokeTransparency = 0.4
                    v680.Text = v671.DisplayName
                    v680.Parent = v679
                    v677 = { k75 = v678, k65 = v679, k79 = v680, k66 = v673 }
                    v665[v671] = v677
                end
                if v677.k67 ~= v676 then
                    v677.k67 = v676
                    v677.k75.FillColor = v676
                    v677.k75.OutlineColor = v676
                    v677.k79.TextColor3 = v676
                end
            else
                v667(v671)
            end
        end
    end
end
task.spawn(function()
    while not v10 do
        pcall(v670)
        task.wait(0.25)
    end
end)

local v681 = {}
local v682 = {}
local v683
local function v684(v685)
    local v686 = v682[v685]
    if v686 then
        return v686
    end
    local v687 = {}
    for _, v688 in v685:GetDescendants() do
        if v688:IsA("BasePart") then
            table.insert(v687, v688)
        end
    end
    v682[v685] = v687
    local v689
    v689 = v685.DescendantAdded:Connect(function(v690)
        if v690:IsA("BasePart") then
            table.insert(v687, v690)
        end
    end)
    v685.AncestryChanged:Once(function()
        v682[v685] = nil
        v689:Disconnect()
    end)
    return v687
end
v12(v2.PreSimulation:Connect(function()
    if not v15.k4 then
        v683 = nil
        return
    end
    local v691, v692 = v41(v8)
    local v693 = os.clock()
    for _, v694 in v1:GetPlayers() do
        if v694 ~= v8 then
            local v695 = v694.Character
            local v696 = v695 and v695:FindFirstChild("HumanoidRootPart")
            if v696 and v691 then
                local v697 = v696.Position - v691.Position
                if v697.X * v697.X + v697.Y * v697.Y + v697.Z * v697.Z < 3600 then
                    local v698 = v696.AssemblyAngularVelocity
                    local v699 = v696.AssemblyLinearVelocity
                    if v698:Dot(v698) > 625 or v699:Dot(v699) > 14400 then
                        v681[v694] = v693 + 3
                    end
                end
            end
            local v700 = v681[v694]
            if v700 then
                if v693 > v700 or not v695 then
                    v681[v694] = nil
                else
                    for _, v701 in v684(v695) do
                        if v701.CanCollide then
                            v701.CanCollide = false
                        end
                    end
                end
            end
        end
    end
    if not v691 then
        v683 = nil
        return
    end
    local v702 = v691.AssemblyLinearVelocity
    local v703 = math.sqrt(v702.X * v702.X + v702.Z * v702.Z)
    local v704 = v691.AssemblyAngularVelocity.Magnitude
    local v705 = v692.WalkSpeed
    if (v703 > math.max(v705 * 5, 90) or v702.Y > 140 or v704 > 35) and v683 then
        v691.AssemblyLinearVelocity = Vector3.zero
        v691.AssemblyAngularVelocity = Vector3.zero
        v691.CFrame = v683
    elseif v703 < v705 * 2 + 4 and v704 < 8 and math.abs(v702.Y) < 60 then
        v683 = v691.CFrame
    end
end))

local v706 = v14:CreateWindow({
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

local v707 = "\u{200B}\u{200C}\u{200B}"
pcall(function()
    v706:EditOpenButton({
        Title = v707,
        Icon = "",
        Transparency = 1,
        StrokeThickness = 0,
    })
end)
local v708 = {}
local function v709()
    local v710 = { game:GetService("CoreGui") }
    if typeof(gethui) == "function" then
        table.insert(v710, gethui())
    end
    local v711 = v8:FindFirstChildOfClass("PlayerGui")
    if v711 then
        table.insert(v710, v711)
    end
    local v712 = false
    for _, v713 in v710 do
        local v714, v715 = pcall(v713.GetDescendants, v713)
        if v714 then
            for _, v716 in v715 do
                if (v716:IsA("TextLabel") or v716:IsA("TextButton")) and v716.Text == v707 then
                    local v717 = v716
                    local v718 = v716.Parent
                    while v718 and v718:IsA("GuiObject") and v718.AbsoluteSize.X * v718.AbsoluteSize.Y < 320 * 160 do
                        v717 = v718
                        v718 = v718.Parent
                    end
                    if v717:IsA("GuiObject") and not v708[v717] then
                        v708[v717] = true
                        v717.Visible = false
                        v12(v717:GetPropertyChangedSignal("Visible"):Connect(function()
                            if v717.Visible then
                                v717.Visible = false
                            end
                        end))
                    end
                    v712 = true
                end
            end
        end
    end
    return v712
end
task.spawn(function()
    for _, v719 in { 0.2, 0.5, 1, 2, 4, 8 } do
        task.wait(v719)
        if v10 then
            return
        end
        local v720, v721 = pcall(v709)
        if v720 and v721 then
            return
        end
    end
end)
local v722 = Enum.KeyCode.K
v12(v4.InputBegan:Connect(function(v723)
    if v723.KeyCode == v722 then
        task.delay(0.15, pcall, v709)
        task.delay(0.6, pcall, v709)
    end
end))

local v724 = v706:Tab({ Title = "Main", Icon = "crosshair" })
v724:Section({ Title = "Silent Aim" })
v724:Toggle({
    Title = "Gun Silent Aim",
    Default = false,
    Callback = function(v725)
        v15.k15 = v725
    end,
})
v724:Toggle({
    Title = "Murderer Silent Aim",
    Default = false,
    Callback = function(v726)
        v15.k26 = v726
    end,
})
v724:Section({ Title = "Knife Throw" })
v724:Toggle({
    Title = "Start Throw Closer",
    Default = false,
    Callback = function(v727)
        v15.k53 = v727
    end,
})
v724:DropDown({
    Title = "Closer Method",
    Option = { "Spoof", "Change" },
    Value = "Spoof",
    Callback = function(v728)
        if v728 == "Spoof" or v728 == "Change" then
            v15.k6 = v728
        end
    end,
})
v724:Slider({
    Title = "Closer By (studs)",
    Step = 1,
    Value = { Min = 1, Max = 40, Default = 8 },
    Callback = function(v729)
        if type(v729) == "number" then
            v15.k5 = v729
        end
    end,
})
v724:Toggle({
    Title = "Skip Throw Charge",
    Default = false,
    Callback = function(v730)
        v15.k47 = v730
        v438.k106 = 0
    end,
})
v724:Slider({
    Title = "Knife Wait For Sure Hit (ms)",
    Step = 10,
    Value = { Min = 0, Max = 600, Default = 0 },
    Callback = function(v731)
        if type(v731) == "number" then
            v15.k27 = v731
            v68.k22 = v731 / 1000
        end
    end,
})
v724:Section({ Title = "Gun Shot" })
v724:Toggle({
    Title = "Start Shot Closer",
    Default = false,
    Callback = function(v732)
        v15.k46 = v732
    end,
})
v724:DropDown({
    Title = "Shot Closer Method",
    Option = { "Spoof", "Change" },
    Value = "Spoof",
    Callback = function(v733)
        if v733 == "Spoof" or v733 == "Change" then
            v15.k17 = v733
        end
    end,
})
v724:Slider({
    Title = "Shot Closer By (studs)",
    Step = 1,
    Value = { Min = 1, Max = 60, Default = 8 },
    Callback = function(v734)
        if type(v734) == "number" then
            v15.k16 = v734
        end
    end,
})
v724:Slider({
    Title = "Gun Wait For Sure Hit (ms)",
    Step = 10,
    Value = { Min = 0, Max = 800, Default = 500 },
    Callback = function(v735)
        if type(v735) == "number" then
            v15.k18 = v735
            v68.k11 = v735 / 1000
        end
    end,
})
v724:Section({ Title = "Other" })
v724:Toggle({
    Title = "ESP",
    Default = false,
    Callback = function(v736)
        v15.k7 = v736
    end,
})
v724:Toggle({
    Title = "Anti Fling",
    Default = false,
    Callback = function(v737)
        v15.k4 = v737
        if not v737 then
            table.clear(v681)
        end
    end,
})

local v738 = v706:Tab({ Title = "Settings", Icon = "settings" })
local v739 = v738:Keybind({
    Title = "Toggle UI",
    Callback = function(v740)
        local v741 = typeof(v740) == "EnumItem" and v740 or Enum.KeyCode[tostring(v740)]
        if v741 then
            v722 = v741
            pcall(v706.SetToggleKey, v706, v741)
        end
    end,
})
pcall(function()
    v739:SetValue("K")
end)

v9.__c55 = function()
    v10 = true
    pcall(v439)
    if v422 then
        pcall(v617, v422)
    end
    for _, v742 in v11 do
        pcall(v742.Disconnect, v742)
    end
    for v743 in v665 do
        v667(v743)
    end
    v664:Destroy()
    if v651 and v650 then
        v650.GetMouseTargetCFrame = v651
        v650.GetTargetPosition = v652
    end
    pcall(v706.Close, v706)
end
