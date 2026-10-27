local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local Brain = (function()
    local band, bxor = bit32.band, bit32.bxor
    local clock = os.clock
    local abs, min, max, floor, log = math.abs, math.min, math.max, math.floor, math.log

    local INF = 1000000
    local MATE = 100000
    local MATE_BOUND = MATE - 1000
    local MAXPLY = 100
    local EXACT, LOWER, UPPER = 0, 1, 2
    local START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    local OFF_N = { 33, 31, 18, 14, -14, -18, -31, -33 }
    local OFF_K = { 17, 16, 15, 1, -1, -15, -16, -17 }
    local OFF_B = { 17, 15, -15, -17 }
    local OFF_R = { 16, 1, -1, -16 }
    local PVAL = { 100, 320, 330, 500, 950, 20000 }
    local PHASE = { 0, 1, 1, 2, 4, 0 }
    local MGV = { 82, 337, 365, 477, 1025, 0 }
    local EGV = { 94, 281, 297, 512, 936, 0 }

    local MGP = {
        {
            0, 0, 0, 0, 0, 0, 0, 0,
            98, 134, 61, 95, 68, 126, 34, -11,
            -6, 7, 26, 31, 65, 56, 25, -20,
            -14, 13, 6, 21, 23, 12, 17, -23,
            -27, -2, -5, 12, 17, 6, 10, -25,
            -26, -4, -4, -10, 3, 3, 33, -12,
            -35, -1, -20, -23, -15, 24, 38, -22,
            0, 0, 0, 0, 0, 0, 0, 0,
        },
        {
            -167, -89, -34, -49, 61, -97, -15, -107,
            -73, -41, 72, 36, 23, 62, 7, -17,
            -47, 60, 37, 65, 84, 129, 73, 44,
            -9, 17, 19, 53, 37, 69, 18, 22,
            -13, 4, 16, 13, 28, 19, 21, -8,
            -23, -9, 12, 10, 19, 17, 25, -16,
            -29, -53, -12, -3, -1, 18, -14, -19,
            -105, -21, -58, -33, -17, -28, -19, -23,
        },
        {
            -29, 4, -82, -37, -25, -42, 7, -8,
            -26, 16, -18, -13, 30, 59, 18, -47,
            -16, 37, 43, 40, 35, 50, 37, -2,
            -4, 5, 19, 50, 37, 37, 7, -2,
            -6, 13, 13, 26, 34, 12, 10, 4,
            0, 15, 15, 15, 14, 27, 18, 10,
            4, 15, 16, 0, 7, 21, 33, 1,
            -33, -3, -14, -21, -13, -12, -39, -21,
        },
        {
            32, 42, 32, 51, 63, 9, 31, 43,
            27, 32, 58, 62, 80, 67, 26, 44,
            -5, 19, 26, 36, 17, 45, 61, 16,
            -24, -11, 7, 26, 24, 35, -8, -20,
            -36, -26, -12, -1, 9, -7, 6, -23,
            -45, -25, -16, -17, 3, 0, -5, -33,
            -44, -16, -20, -9, -1, 11, -6, -71,
            -19, -13, 1, 17, 16, 7, -37, -26,
        },
        {
            -28, 0, 29, 12, 59, 44, 43, 45,
            -24, -39, -5, 1, -16, 57, 28, 54,
            -13, -17, 7, 8, 29, 56, 47, 57,
            -27, -27, -16, -16, -1, 17, -2, 1,
            -9, -26, -9, -10, -2, -4, 3, -3,
            -14, 2, -11, -2, -5, 2, 14, 5,
            -35, -8, 11, 2, 8, 15, -3, 1,
            -1, -18, -9, 10, -15, -25, -31, -50,
        },
        {
            -65, 23, 16, -15, -56, -34, 2, 13,
            29, -1, -20, -7, -8, -4, -38, -29,
            -9, 24, 2, -16, -20, 6, 22, -22,
            -17, -20, -12, -27, -30, -25, -14, -36,
            -49, -1, -27, -39, -46, -44, -33, -51,
            -14, -14, -22, -46, -44, -30, -15, -27,
            1, 7, -8, -64, -43, -16, 9, 8,
            -15, 36, 12, -54, 8, -28, 24, 14,
        },
    }

    local EGP = {
        {
            0, 0, 0, 0, 0, 0, 0, 0,
            178, 173, 158, 134, 147, 132, 165, 187,
            94, 100, 85, 67, 56, 53, 82, 84,
            32, 24, 13, 5, -2, 4, 17, 17,
            13, 9, -3, -7, -7, -8, 3, -1,
            4, 7, -6, 1, 0, -5, -1, -8,
            13, 8, 8, 10, 13, 0, 2, -7,
            0, 0, 0, 0, 0, 0, 0, 0,
        },
        {
            -58, -38, -13, -28, -31, -27, -63, -99,
            -25, -8, -25, -2, -9, -25, -24, -52,
            -24, -20, 10, 9, -1, -9, -19, -41,
            -17, 3, 22, 22, 22, 11, 8, -18,
            -18, -6, 16, 25, 16, 17, 4, -18,
            -23, -3, -1, 15, 10, -3, -20, -22,
            -42, -20, -10, -5, -2, -20, -23, -44,
            -29, -51, -23, -15, -22, -18, -50, -64,
        },
        {
            -14, -21, -11, -8, -7, -9, -17, -24,
            -8, -4, 7, -12, -3, -13, -4, -14,
            2, -8, 0, -1, -2, 6, 0, 4,
            -3, 9, 12, 9, 14, 10, 3, 2,
            -6, 3, 13, 19, 7, 10, -3, -9,
            -12, -3, 8, 10, 13, 3, -7, -15,
            -14, -18, -7, -1, 4, -9, -15, -27,
            -23, -9, -23, -5, -9, -16, -5, -17,
        },
        {
            13, 10, 18, 15, 12, 12, 8, 5,
            11, 13, 13, 11, -3, 3, 8, 3,
            7, 7, 7, 5, 4, -3, -5, -3,
            4, 3, 13, 1, 2, 1, -1, 2,
            3, 5, 8, 4, -5, -6, -8, -11,
            -4, 0, -5, -1, -7, -12, -8, -16,
            -6, -6, 0, 2, -9, -9, -11, -3,
            -9, 2, 3, -1, -5, -13, 4, -20,
        },
        {
            -9, 22, 22, 27, 27, 19, 10, 20,
            -17, 20, 32, 41, 58, 25, 30, 0,
            -20, 6, 9, 49, 47, 35, 19, 9,
            3, 22, 24, 45, 57, 40, 57, 36,
            -18, 28, 19, 47, 31, 34, 39, 23,
            -16, -27, 15, 6, 9, 17, 10, 5,
            -22, -23, -30, -16, -16, -23, -36, -32,
            -33, -28, -22, -43, -5, -32, -20, -41,
        },
        {
            -74, -35, -18, -18, -11, 15, 4, -17,
            -12, 17, 14, 17, 17, 38, 23, 11,
            10, 17, 23, 15, 20, 45, 44, 13,
            -8, 22, 24, 27, 26, 33, 26, 3,
            -18, -4, 21, 24, 27, 23, 9, -11,
            -19, -3, 11, 21, 23, 16, 7, -9,
            -27, -11, 4, 13, 14, 4, -5, -17,
            -53, -34, -21, -11, -28, -14, -24, -43,
        },
    }

    local PASS_MG = { 0, 5, 10, 15, 30, 55, 90, 0 }
    local PASS_EG = { 0, 10, 15, 30, 55, 95, 150, 0 }

    local SQ = {}
    for r = 0, 7 do
        for f = 0, 7 do
            SQ[#SQ + 1] = r * 16 + f
        end
    end

    local function rnd()
        return math.random(0, 65535) * 65536 + math.random(0, 65535)
    end

    local MGT, EGT, Z1, Z2 = {}, {}, {}, {}
    for t = 1, 6 do
        for c = 0, 1 do
            local code = t + c * 8
            local mgt, egt, z1, z2 = {}, {}, {}, {}
            for r = 0, 7 do
                for f = 0, 7 do
                    local sq = r * 16 + f
                    local i = (c == 0 and (7 - r) * 8 + f or r * 8 + f) + 1
                    mgt[sq] = MGV[t] + MGP[t][i]
                    egt[sq] = EGV[t] + EGP[t][i]
                    z1[sq] = rnd()
                    z2[sq] = rnd()
                end
            end
            MGT[code], EGT[code], Z1[code], Z2[code] = mgt, egt, z1, z2
        end
    end

    local ZS1, ZS2 = rnd(), rnd()
    local ZC1, ZC2, ZE1, ZE2 = {}, {}, {}, {}
    for i = 0, 15 do
        ZC1[i], ZC2[i] = rnd(), rnd()
    end
    for i = 0, 7 do
        ZE1[i], ZE2[i] = rnd(), rnd()
    end

    local CM = {}
    for i = 0, 127 do
        CM[i] = 15
    end
    CM[0], CM[4], CM[7] = 13, 12, 14
    CM[112], CM[116], CM[119] = 7, 3, 11

    local LMR = {}
    for d = 1, 64 do
        LMR[d] = {}
        for m = 1, 64 do
            LMR[d][m] = floor(0.8 + log(d) * log(m) / 2.4)
        end
    end

    local board = {}
    for i = 0, 127 do
        board[i] = 0
    end
    local cnt = {}
    for i = 0, 15 do
        cnt[i] = 0
    end
    local kingSq = { [0] = 4, [1] = 116 }
    local side, castle, ep, half = 0, 0, -1, 0
    local h1, h2, ph1, ph2 = 0, 0, 0, 0
    local mg, eg, phase = 0, 0, 0

    local sp, hp = 0, 0
    local STM, SCap, SC, SE, SH, S1, S2, SP1, SP2 = {}, {}, {}, {}, {}, {}, {}, {}, {}
    local HH1, HH2 = {}, {}

    local TBITS = 2 ^ 18
    local TMASK = TBITS - 1
    local TK1 = table.create(TBITS, -1)
    local TK2 = table.create(TBITS, -1)
    local TMV = table.create(TBITS, 0)
    local TDP = table.create(TBITS, 0)
    local TSC = table.create(TBITS, 0)
    local TFL = table.create(TBITS, 0)

    local PBITS = 2 ^ 14
    local PMASK = PBITS - 1
    local PK1 = table.create(PBITS, -1)
    local PK2 = table.create(PBITS, -1)
    local PM = table.create(PBITS, 0)
    local PE = table.create(PBITS, 0)

    local HIST = {}
    for c = 0, 15 do
        HIST[c] = table.create(128, 0)
        HIST[c][0] = 0
    end
    local K1, K2 = {}, {}
    local ML, MS = {}, {}
    for p = 0, MAXPLY + 2 do
        ML[p], MS[p] = {}, {}
        K1[p], K2[p] = 0, 0
    end

    local nodes, deadline, sliceStart, stopped, canStop = 0, 0, 0, false, false
    local yieldFn, SLICE = nil, 0.012
    local rootBest, rootScore = 0, 0

    local function addPiece(sq, p)
        board[sq] = p
        local t = p % 8
        if p < 8 then
            mg += MGT[p][sq]
            eg += EGT[p][sq]
        else
            mg -= MGT[p][sq]
            eg -= EGT[p][sq]
        end
        phase += PHASE[t]
        cnt[p] += 1
        local k1, k2 = Z1[p][sq], Z2[p][sq]
        h1 = bxor(h1, k1)
        h2 = bxor(h2, k2)
        if t == 1 or t == 6 then
            ph1 = bxor(ph1, k1)
            ph2 = bxor(ph2, k2)
        end
    end

    local function removePiece(sq)
        local p = board[sq]
        board[sq] = 0
        local t = p % 8
        if p < 8 then
            mg -= MGT[p][sq]
            eg -= EGT[p][sq]
        else
            mg += MGT[p][sq]
            eg += EGT[p][sq]
        end
        phase -= PHASE[t]
        cnt[p] -= 1
        local k1, k2 = Z1[p][sq], Z2[p][sq]
        h1 = bxor(h1, k1)
        h2 = bxor(h2, k2)
        if t == 1 or t == 6 then
            ph1 = bxor(ph1, k1)
            ph2 = bxor(ph2, k2)
        end
        return p
    end

    local function attacked(sq, by)
        local a
        if by == 0 then
            a = sq - 15
            if band(a, 0x88) == 0 and board[a] == 1 then return true end
            a = sq - 17
            if band(a, 0x88) == 0 and board[a] == 1 then return true end
        else
            a = sq + 15
            if band(a, 0x88) == 0 and board[a] == 9 then return true end
            a = sq + 17
            if band(a, 0x88) == 0 and board[a] == 9 then return true end
        end
        local o = by * 8
        local kn, bi, rk, qn, kg = 2 + o, 3 + o, 4 + o, 5 + o, 6 + o
        for i = 1, 8 do
            a = sq + OFF_N[i]
            if band(a, 0x88) == 0 and board[a] == kn then return true end
            a = sq + OFF_K[i]
            if band(a, 0x88) == 0 and board[a] == kg then return true end
        end
        for i = 1, 4 do
            local d = OFF_B[i]
            a = sq + d
            while band(a, 0x88) == 0 do
                local q = board[a]
                if q ~= 0 then
                    if q == bi or q == qn then return true end
                    break
                end
                a += d
            end
            d = OFF_R[i]
            a = sq + d
            while band(a, 0x88) == 0 do
                local q = board[a]
                if q ~= 0 then
                    if q == rk or q == qn then return true end
                    break
                end
                a += d
            end
        end
        return false
    end

    local function makeMove(m)
        local from = m % 128
        local to = (m // 128) % 128
        local promo = (m // 16384) % 8
        local flag = m // 131072
        sp += 1
        STM[sp], SC[sp], SE[sp], SH[sp] = m, castle, ep, half
        S1[sp], S2[sp], SP1[sp], SP2[sp] = h1, h2, ph1, ph2
        hp += 1
        HH1[hp], HH2[hp] = h1, h2
        local p = board[from]
        local cap = board[to]
        SCap[sp] = cap
        if ep >= 0 then
            h1 = bxor(h1, ZE1[ep % 16])
            h2 = bxor(h2, ZE2[ep % 16])
            ep = -1
        end
        half += 1
        if cap ~= 0 then
            removePiece(to)
            half = 0
        end
        removePiece(from)
        if promo ~= 0 then
            addPiece(to, promo + side * 8)
        else
            addPiece(to, p)
        end
        local t = p % 8
        if t == 1 then
            half = 0
            if flag == 2 then
                removePiece(side == 0 and to - 16 or to + 16)
            elseif flag == 1 then
                local enemy = 9 - side * 8
                local l, r = to - 1, to + 1
                if (band(l, 0x88) == 0 and board[l] == enemy) or (band(r, 0x88) == 0 and board[r] == enemy) then
                    ep = (from + to) // 2
                    h1 = bxor(h1, ZE1[ep % 16])
                    h2 = bxor(h2, ZE2[ep % 16])
                end
            end
        elseif t == 6 then
            kingSq[side] = to
            if flag == 3 then
                if to > from then
                    addPiece(from + 1, removePiece(from + 3))
                else
                    addPiece(from - 1, removePiece(from - 4))
                end
            end
        end
        local nc = band(castle, CM[from], CM[to])
        if nc ~= castle then
            h1 = bxor(h1, ZC1[castle], ZC1[nc])
            h2 = bxor(h2, ZC2[castle], ZC2[nc])
            castle = nc
        end
        side = 1 - side
        h1 = bxor(h1, ZS1)
        h2 = bxor(h2, ZS2)
    end

    local function unmakeMove()
        local m = STM[sp]
        local from = m % 128
        local to = (m // 128) % 128
        local promo = (m // 16384) % 8
        local flag = m // 131072
        side = 1 - side
        local p = removePiece(to)
        if promo ~= 0 then p = 1 + side * 8 end
        addPiece(from, p)
        local cap = SCap[sp]
        if cap ~= 0 then addPiece(to, cap) end
        if flag == 2 then
            addPiece(side == 0 and to - 16 or to + 16, 9 - side * 8)
        elseif flag == 3 then
            if to > from then
                addPiece(from + 3, removePiece(from + 1))
            else
                addPiece(from - 4, removePiece(from - 1))
            end
        end
        if p % 8 == 6 then kingSq[side] = from end
        castle, ep, half = SC[sp], SE[sp], SH[sp]
        h1, h2, ph1, ph2 = S1[sp], S2[sp], SP1[sp], SP2[sp]
        sp -= 1
        hp -= 1
    end

    local function makeNull()
        sp += 1
        STM[sp], SC[sp], SE[sp], SH[sp] = 0, castle, ep, half
        S1[sp], S2[sp], SP1[sp], SP2[sp] = h1, h2, ph1, ph2
        hp += 1
        HH1[hp], HH2[hp] = h1, h2
        if ep >= 0 then
            h1 = bxor(h1, ZE1[ep % 16])
            h2 = bxor(h2, ZE2[ep % 16])
            ep = -1
        end
        half = 0
        side = 1 - side
        h1 = bxor(h1, ZS1)
        h2 = bxor(h2, ZS2)
    end

    local function unmakeNull()
        side = 1 - side
        castle, ep, half = SC[sp], SE[sp], SH[sp]
        h1, h2, ph1, ph2 = S1[sp], S2[sp], SP1[sp], SP2[sp]
        sp -= 1
        hp -= 1
    end

    local GL, GS, GN, GPly

    local function addCap(from, to, p, victim, promo)
        GN += 1
        GL[GN] = from + to * 128 + promo * 16384
        GS[GN] = 1000000 + PVAL[victim % 8] * 10 - (p % 8) + (promo == 5 and 500000 or 0)
    end

    local function addQuiet(from, to, p, flag)
        local m = from + to * 128 + flag * 131072
        GN += 1
        GL[GN] = m
        if m == K1[GPly] then
            GS[GN] = 900000
        elseif m == K2[GPly] then
            GS[GN] = 800000
        else
            GS[GN] = HIST[p][to]
        end
    end

    local function addPromos(from, to, victim, capsOnly)
        local base = from + to * 128
        local vb = victim ~= 0 and PVAL[victim % 8] * 10 or 0
        GN += 1
        GL[GN] = base + 5 * 16384
        GS[GN] = 1500000 + vb
        if not capsOnly then
            for pr = 4, 2, -1 do
                GN += 1
                GL[GN] = base + pr * 16384
                GS[GN] = (pr == 2 and 700000 or -1000) + vb
            end
        end
    end

    local function gen(list, scores, capsOnly, ply)
        GL, GS, GN, GPly = list, scores, 0, ply
        local us = side
        local ub = us == 1
        for i = 1, 64 do
            local sq = SQ[i]
            local p = board[sq]
            if p ~= 0 and (p > 8) == ub then
                local t = p % 8
                if t == 1 then
                    local dir = ub and -16 or 16
                    local to = sq + dir
                    local promoRank = to >= 112 or to < 8
                    if board[to] == 0 then
                        if promoRank then
                            addPromos(sq, to, 0, capsOnly)
                        elseif not capsOnly then
                            addQuiet(sq, to, p, 0)
                            local r = sq // 16
                            if (r == 1 and not ub) or (r == 6 and ub) then
                                local to2 = to + dir
                                if board[to2] == 0 then addQuiet(sq, to2, p, 1) end
                            end
                        end
                    end
                    for k = -1, 1, 2 do
                        local c = to + k
                        if band(c, 0x88) == 0 then
                            local q = board[c]
                            if q ~= 0 then
                                if (q > 8) ~= ub then
                                    if promoRank then
                                        addPromos(sq, c, q, capsOnly)
                                    else
                                        addCap(sq, c, p, q, 0)
                                    end
                                end
                            elseif c == ep then
                                GN += 1
                                GL[GN] = sq + c * 128 + 2 * 131072
                                GS[GN] = 1000000 + 999
                            end
                        end
                    end
                elseif t == 2 or t == 6 then
                    local offs = t == 2 and OFF_N or OFF_K
                    for k = 1, 8 do
                        local to = sq + offs[k]
                        if band(to, 0x88) == 0 then
                            local q = board[to]
                            if q == 0 then
                                if not capsOnly then addQuiet(sq, to, p, 0) end
                            elseif (q > 8) ~= ub then
                                addCap(sq, to, p, q, 0)
                            end
                        end
                    end
                    if t == 6 and not capsOnly then
                        local them = 1 - us
                        if us == 0 and sq == 4 then
                            if band(castle, 1) ~= 0 and board[5] == 0 and board[6] == 0 and board[7] == 4
                                and not attacked(4, them) and not attacked(5, them) then
                                addQuiet(4, 6, p, 3)
                            end
                            if band(castle, 2) ~= 0 and board[3] == 0 and board[2] == 0 and board[1] == 0 and board[0] == 4
                                and not attacked(4, them) and not attacked(3, them) then
                                addQuiet(4, 2, p, 3)
                            end
                        elseif us == 1 and sq == 116 then
                            if band(castle, 4) ~= 0 and board[117] == 0 and board[118] == 0 and board[119] == 12
                                and not attacked(116, them) and not attacked(117, them) then
                                addQuiet(116, 118, p, 3)
                            end
                            if band(castle, 8) ~= 0 and board[115] == 0 and board[114] == 0 and board[113] == 0 and board[112] == 12
                                and not attacked(116, them) and not attacked(115, them) then
                                addQuiet(116, 114, p, 3)
                            end
                        end
                    end
                else
                    local s1, s2 = 1, 4
                    if t == 3 then
                        s2 = 0
                    elseif t == 4 then
                        s1 = 0
                    end
                    for pass = 1, 2 do
                        local offs = pass == 1 and OFF_B or OFF_R
                        if (pass == 1 and s1 ~= 0) or (pass == 2 and s2 ~= 0) then
                            for k = 1, 4 do
                                local d = offs[k]
                                local to = sq + d
                                while band(to, 0x88) == 0 do
                                    local q = board[to]
                                    if q == 0 then
                                        if not capsOnly then addQuiet(sq, to, p, 0) end
                                    else
                                        if (q > 8) ~= ub then addCap(sq, to, p, q, 0) end
                                        break
                                    end
                                    to += d
                                end
                            end
                        end
                    end
                end
            end
        end
        return GN
    end

    local WF, BF, WMIN, BMAX = {}, {}, {}, {}
    local PW, PB = {}, {}

    local function pawnEval()
        for f = -1, 8 do
            WF[f], BF[f], WMIN[f], BMAX[f] = 0, 0, 8, -1
        end
        local nw, nb = 0, 0
        for i = 1, 64 do
            local sq = SQ[i]
            local p = board[sq]
            if p == 1 then
                local f, r = sq % 16, sq // 16
                WF[f] += 1
                if r < WMIN[f] then WMIN[f] = r end
                nw += 1
                PW[nw] = sq
            elseif p == 9 then
                local f, r = sq % 16, sq // 16
                BF[f] += 1
                if r > BMAX[f] then BMAX[f] = r end
                nb += 1
                PB[nb] = sq
            end
        end
        local m, e = 0, 0
        for f = 0, 7 do
            if WF[f] > 1 then
                m -= 10 * (WF[f] - 1)
                e -= 25 * (WF[f] - 1)
            end
            if BF[f] > 1 then
                m += 10 * (BF[f] - 1)
                e += 25 * (BF[f] - 1)
            end
        end
        for i = 1, nw do
            local sq = PW[i]
            local f, r = sq % 16, sq // 16
            if WF[f - 1] == 0 and WF[f + 1] == 0 then
                m -= 12
                e -= 15
            end
            if BMAX[f - 1] <= r and BMAX[f] <= r and BMAX[f + 1] <= r then
                m += PASS_MG[r + 1]
                e += PASS_EG[r + 1]
            end
        end
        for i = 1, nb do
            local sq = PB[i]
            local f, r = sq % 16, sq // 16
            if BF[f - 1] == 0 and BF[f + 1] == 0 then
                m += 12
                e += 15
            end
            if WMIN[f - 1] >= r and WMIN[f] >= r and WMIN[f + 1] >= r then
                m -= PASS_MG[8 - r]
                e -= PASS_EG[8 - r]
            end
        end
        local wk, bk = kingSq[0], kingSq[1]
        local shield = 0
        local wkf = wk % 16
        if wk < 16 then
            for f = max(0, wkf - 1), min(7, wkf + 1) do
                local p1, p2 = board[16 + f], board[32 + f]
                if p1 == 1 then shield += 12 elseif p2 == 1 then shield += 6 else shield -= 10 end
            end
        end
        local bkf = bk % 16
        if bk >= 112 then
            for f = max(0, bkf - 1), min(7, bkf + 1) do
                local p1, p2 = board[96 + f], board[80 + f]
                if p1 == 9 then shield -= 12 elseif p2 == 9 then shield -= 6 else shield += 10 end
            end
        end
        m += shield
        return m, e
    end

    local function evaluate()
        local ph = phase
        if ph > 24 then ph = 24 end
        local m, e = mg, eg
        local idx = band(ph1, PMASK) + 1
        if PK1[idx] == ph1 and PK2[idx] == ph2 then
            m += PM[idx]
            e += PE[idx]
        else
            local pm, pe = pawnEval()
            PK1[idx], PK2[idx], PM[idx], PE[idx] = ph1, ph2, pm, pe
            m += pm
            e += pe
        end
        if cnt[3] >= 2 then
            m += 30
            e += 50
        end
        if cnt[11] >= 2 then
            m -= 30
            e -= 50
        end
        local s = (m * ph + e * (24 - ph)) // 24
        if ph <= 7 and (s > 250 or s < -250) then
            local wk, bk = kingSq[0], kingSq[1]
            local loser = s > 0 and bk or wk
            local lf, lr = loser % 16, loser // 16
            local cd = max(3 - lf, lf - 4) + max(3 - lr, lr - 4)
            local kd = abs(wk % 16 - bk % 16) + abs(wk // 16 - bk // 16)
            local bonus = cd * 12 + (14 - kd) * 5
            if s > 0 then s += bonus else s -= bonus end
        end
        if s > 0 and cnt[1] == 0 and cnt[4] + cnt[5] == 0 and cnt[2] + cnt[3] <= 1 then s = 0 end
        if s < 0 and cnt[9] == 0 and cnt[12] + cnt[13] == 0 and cnt[10] + cnt[11] <= 1 then s = 0 end
        return (side == 0 and s or -s) + 12
    end

    local function insufficient()
        if cnt[1] + cnt[9] + cnt[4] + cnt[12] + cnt[5] + cnt[13] ~= 0 then return false end
        return cnt[2] + cnt[3] + cnt[10] + cnt[11] <= 1
    end

    local function isRep()
        local stop = hp - half + 1
        if stop < 1 then stop = 1 end
        for i = hp - 1, stop, -2 do
            if HH1[i] == h1 and HH2[i] == h2 then return true end
        end
        return false
    end

    local function hasPieces(s)
        local o = s * 8
        return cnt[2 + o] + cnt[3 + o] + cnt[4 + o] + cnt[5 + o] > 0
    end

    local function poll()
        local now = clock()
        if canStop and now >= deadline then
            stopped = true
            return
        end
        if yieldFn and now - sliceStart >= SLICE then
            yieldFn()
            sliceStart = clock()
        end
    end

    local function pick(list, scores, i, n)
        local bi, bs = i, scores[i]
        for j = i + 1, n do
            if scores[j] > bs then
                bi, bs = j, scores[j]
            end
        end
        if bi ~= i then
            list[i], list[bi] = list[bi], list[i]
            scores[i], scores[bi] = scores[bi], scores[i]
        end
        return list[i]
    end

    local function qsearch(alpha, beta, ply)
        nodes += 1
        if band(nodes, 1023) == 0 then poll() end
        if stopped then return 0 end
        local stand = evaluate()
        if ply >= MAXPLY then return stand end
        if stand >= beta then return stand end
        if stand > alpha then alpha = stand end
        local list, scores = ML[ply], MS[ply]
        local n = gen(list, scores, true, ply)
        for i = 1, n do
            local m = pick(list, scores, i, n)
            local to = (m // 128) % 128
            local promo = (m // 16384) % 8
            local victim = board[to]
            local gain = victim ~= 0 and PVAL[victim % 8] or 100
            if promo ~= 0 then gain += 800 end
            if stand + gain + 200 > alpha then
                makeMove(m)
                if attacked(kingSq[1 - side], side) then
                    unmakeMove()
                else
                    local sc = -qsearch(-beta, -alpha, ply + 1)
                    unmakeMove()
                    if stopped then return 0 end
                    if sc > alpha then
                        if sc >= beta then return sc end
                        alpha = sc
                    end
                end
            end
        end
        return alpha
    end

    local function bumpHistory(p, to, bonus)
        local row = HIST[p]
        local v = row[to] + bonus
        row[to] = v
        if v > 400000 then
            for c = 0, 15 do
                local r = HIST[c]
                for s = 0, 127 do
                    r[s] = r[s] // 2
                end
            end
        end
    end

    local function negamax(depth, alpha, beta, ply, doNull)
        if ply > 0 then
            if half >= 100 or isRep() or insufficient() then return 0 end
            local ma = -MATE + ply
            if alpha < ma then alpha = ma end
            local mb = MATE - ply - 1
            if beta > mb then beta = mb end
            if alpha >= beta then return alpha end
        end
        local inCheck = attacked(kingSq[side], 1 - side)
        if inCheck then depth += 1 end
        if depth <= 0 or ply >= MAXPLY - 4 then return qsearch(alpha, beta, ply) end
        nodes += 1
        if band(nodes, 1023) == 0 then poll() end
        if stopped then return 0 end
        local pv = beta - alpha > 1
        local idx = band(h1, TMASK) + 1
        local ttMove = 0
        if TK1[idx] == h1 and TK2[idx] == h2 then
            ttMove = TMV[idx]
            if not pv and ply > 0 and TDP[idx] >= depth then
                local sc = TSC[idx]
                if sc > MATE_BOUND then
                    sc -= ply
                elseif sc < -MATE_BOUND then
                    sc += ply
                end
                local fl = TFL[idx]
                if fl == EXACT or (fl == LOWER and sc >= beta) or (fl == UPPER and sc <= alpha) then return sc end
            end
        end
        local ev = 0
        if not inCheck then ev = evaluate() end
        if not pv and not inCheck and abs(beta) < MATE_BOUND then
            if depth <= 6 and ev - 85 * depth >= beta then return ev end
            if doNull and depth >= 3 and ev >= beta and hasPieces(side) then
                local R = 3 + depth // 6
                makeNull()
                local sc = -negamax(depth - 1 - R, -beta, -beta + 1, ply + 1, false)
                unmakeNull()
                if stopped then return 0 end
                if sc >= beta then
                    if sc > MATE_BOUND then sc = beta end
                    return sc
                end
            end
        end
        if pv and ttMove == 0 and depth >= 5 then depth -= 1 end
        local list, scores = ML[ply], MS[ply]
        local n = gen(list, scores, false, ply)
        if ttMove ~= 0 then
            for i = 1, n do
                if list[i] == ttMove then
                    scores[i] = 100000000
                    break
                end
            end
        end
        local futile = not pv and not inCheck and depth <= 3 and ev + 90 + 110 * depth <= alpha
        local lmpLimit = 3 + depth * depth * 2
        local best, bestMove, legal = -INF, 0, 0
        local origAlpha = alpha
        for i = 1, n do
            local m = pick(list, scores, i, n)
            local from = m % 128
            local to = (m // 128) % 128
            local p = board[from]
            local flag = m // 131072
            local quiet = board[to] == 0 and (m // 16384) % 8 == 0 and flag ~= 2
            makeMove(m)
            if attacked(kingSq[1 - side], side) then
                unmakeMove()
            else
                legal += 1
                local gives = attacked(kingSq[side], 1 - side)
                local skip = false
                if quiet and not gives and not inCheck and legal > 1 and best > -MATE_BOUND then
                    if futile then
                        skip = true
                    elseif not pv and depth <= 4 and legal > lmpLimit then
                        skip = true
                    end
                end
                if skip then
                    unmakeMove()
                else
                    local sc
                    if legal == 1 then
                        sc = -negamax(depth - 1, -beta, -alpha, ply + 1, true)
                    else
                        local r = 0
                        if depth >= 3 and quiet and not inCheck and not gives and m ~= K1[ply] and m ~= K2[ply] then
                            r = LMR[min(depth, 64)][min(legal, 64)]
                            if pv then r -= 1 end
                            if HIST[p][to] > 20000 then r -= 1 end
                            if r < 0 then r = 0 end
                            if r > depth - 2 then r = depth - 2 end
                        end
                        sc = -negamax(depth - 1 - r, -alpha - 1, -alpha, ply + 1, true)
                        if sc > alpha and r > 0 then
                            sc = -negamax(depth - 1, -alpha - 1, -alpha, ply + 1, true)
                        end
                        if sc > alpha and sc < beta then
                            sc = -negamax(depth - 1, -beta, -alpha, ply + 1, true)
                        end
                    end
                    unmakeMove()
                    if stopped then return 0 end
                    if sc > best then
                        best, bestMove = sc, m
                        if sc > alpha then
                            alpha = sc
                            if ply == 0 then
                                rootBest, rootScore = m, sc
                            end
                            if sc >= beta then
                                if quiet then
                                    if K1[ply] ~= m then
                                        K2[ply] = K1[ply]
                                        K1[ply] = m
                                    end
                                    bumpHistory(p, to, depth * depth)
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
        if legal == 0 then
            return inCheck and (-MATE + ply) or 0
        end
        local fl = best >= beta and LOWER or (best > origAlpha and EXACT or UPPER)
        local st = best
        if st > MATE_BOUND then
            st += ply
        elseif st < -MATE_BOUND then
            st -= ply
        end
        TK1[idx], TK2[idx], TMV[idx], TDP[idx], TSC[idx], TFL[idx] = h1, h2, bestMove, depth, st, fl
        return best
    end

    local function sqName(sq)
        return string.char(97 + sq % 16) .. tostring(sq // 16 + 1)
    end

    local function nameSq(s)
        if type(s) ~= "string" or #s ~= 2 then return nil end
        local f = s:byte(1) - 97
        local r = s:byte(2) - 49
        if f < 0 or f > 7 or r < 0 or r > 7 then return nil end
        return r * 16 + f
    end

    local PROMO_CHAR = { [2] = "n", [3] = "b", [4] = "r", [5] = "q" }
    local CHAR_PROMO = { n = 2, b = 3, r = 4, q = 5 }

    local function toUci(m)
        local from = m % 128
        local to = (m // 128) % 128
        local promo = (m // 16384) % 8
        return sqName(from) .. sqName(to) .. (PROMO_CHAR[promo] or "")
    end

    local function legalMoves()
        local list, scores = {}, {}
        local n = gen(list, scores, false, MAXPLY + 1)
        local out = {}
        for i = 1, n do
            local m = list[i]
            makeMove(m)
            if not attacked(kingSq[1 - side], side) then out[#out + 1] = m end
            unmakeMove()
        end
        return out
    end

    local function findMove(uci)
        if type(uci) ~= "string" or #uci < 4 then return nil end
        local from, to = nameSq(uci:sub(1, 2)), nameSq(uci:sub(3, 4))
        if not from or not to then return nil end
        local promo = CHAR_PROMO[uci:sub(5, 5):lower()] or 0
        local p = board[from]
        if p % 8 == 6 and abs(to - from) ~= 2 and abs(to - from) ~= 1 and abs(to - from) ~= 15 and abs(to - from) ~= 16 and abs(to - from) ~= 17 then
            if to == from + 3 or to == from - 4 then
                to = to > from and from + 2 or from - 2
            end
        end
        local fallback
        for _, m in ipairs(legalMoves()) do
            if m % 128 == from and (m // 128) % 128 == to then
                local mp = (m // 16384) % 8
                if mp == promo then return m end
                if mp == 5 then fallback = m end
            end
        end
        return fallback
    end

    local FEN_PIECE = { P = 1, N = 2, B = 3, R = 4, Q = 5, K = 6, p = 9, n = 10, b = 11, r = 12, q = 13, k = 14 }

    local function loadFen(fen)
        for i = 0, 127 do
            board[i] = 0
        end
        for i = 0, 15 do
            cnt[i] = 0
        end
        h1, h2, ph1, ph2, mg, eg, phase = 0, 0, 0, 0, 0, 0, 0
        sp, hp = 0, 0
        local parts = {}
        for w in tostring(fen or START_FEN):gmatch("%S+") do
            parts[#parts + 1] = w
        end
        local placement = parts[1] or ""
        local r, f = 7, 0
        for ch in placement:gmatch(".") do
            if ch == "/" then
                r -= 1
                f = 0
            elseif ch:match("%d") then
                f += tonumber(ch)
            else
                local p = FEN_PIECE[ch]
                if p and r >= 0 and f <= 7 then
                    local sq = r * 16 + f
                    addPiece(sq, p)
                    if p == 6 then kingSq[0] = sq elseif p == 14 then kingSq[1] = sq end
                end
                f += 1
            end
        end
        side = parts[2] == "b" and 1 or 0
        castle = 0
        local c = parts[3] or "-"
        if c:find("K") and board[4] == 6 and board[7] == 4 then castle += 1 end
        if c:find("Q") and board[4] == 6 and board[0] == 4 then castle += 2 end
        if c:find("k") and board[116] == 14 and board[119] == 12 then castle += 4 end
        if c:find("q") and board[116] == 14 and board[112] == 12 then castle += 8 end
        ep = nameSq(parts[4] or "-") or -1
        half = tonumber(parts[5] or "0") or 0
        h1 = bxor(h1, ZC1[castle])
        h2 = bxor(h2, ZC2[castle])
        if ep >= 0 then
            h1 = bxor(h1, ZE1[ep % 16])
            h2 = bxor(h2, ZE2[ep % 16])
        end
        if side == 1 then
            h1 = bxor(h1, ZS1)
            h2 = bxor(h2, ZS2)
        end
        return cnt[6] == 1 and cnt[14] == 1
    end

    local function setPosition(fen, ucis)
        if not loadFen(fen) then return false end
        for _, u in ipairs(ucis or {}) do
            local m = findMove(u)
            if not m then return false end
            makeMove(m)
        end
        sp = 0
        return true
    end

    local function perft(depth)
        if depth == 0 then return 1 end
        local list, scores = ML[depth], MS[depth]
        local n = gen(list, scores, false, depth)
        local moves = table.move(list, 1, n, 1, {})
        local total = 0
        for i = 1, n do
            makeMove(moves[i])
            if not attacked(kingSq[1 - side], side) then total += perft(depth - 1) end
            unmakeMove()
        end
        return total
    end

    local function think(seconds, maxDepth, yielder)
        local start = clock()
        deadline = start + (seconds or 1)
        sliceStart = start
        yieldFn = yielder
        stopped, canStop, nodes = false, false, 0
        maxDepth = maxDepth or 64
        for c = 0, 15 do
            local row = HIST[c]
            for s = 0, 127 do
                row[s] = row[s] // 4
            end
        end
        for p = 0, MAXPLY + 2 do
            K1[p], K2[p] = 0, 0
        end
        local moves = legalMoves()
        if #moves == 0 then return nil end
        local bestMove, bestScore, doneDepth = moves[1], evaluate(), 0
        if #moves == 1 then
            return { best = toUci(bestMove), score = bestScore, depth = 0, nodes = 0 }
        end
        local prev = 0
        for d = 1, maxDepth do
            rootBest = 0
            local sc
            if d >= 5 and abs(prev) < MATE_BOUND then
                local w = 35
                local a, b = prev - w, prev + w
                while true do
                    sc = negamax(d, a, b, 0, true)
                    if stopped then break end
                    if sc <= a then
                        a = sc - w
                    elseif sc >= b then
                        b = sc + w
                    else
                        break
                    end
                    w *= 2
                    if w > 600 then a, b = -INF, INF end
                end
            else
                sc = negamax(d, -INF, INF, 0, true)
            end
            if stopped then
                if rootBest ~= 0 then bestMove = rootBest end
                break
            end
            if rootBest ~= 0 then bestMove = rootBest end
            bestScore, doneDepth, prev = sc, d, sc
            canStop = true
            if abs(sc) > MATE_BOUND and d >= (MATE - abs(sc)) + 1 then break end
            if clock() - start > (seconds or 1) * 0.5 then break end
        end
        yieldFn = nil
        local res = { best = toUci(bestMove), score = bestScore, depth = doneDepth, nodes = nodes }
        if abs(bestScore) > MATE_BOUND then
            local plies = MATE - abs(bestScore)
            local moves2 = (plies + 1) // 2
            res.mate = bestScore > 0 and moves2 or -moves2
        end
        return res
    end

    local busy = false

    local function analyse(fen, ucis, seconds, maxDepth, yielder)
        while busy do
            if yielder then yielder() else return nil end
        end
        busy = true
        local ok, res = pcall(function()
            if not setPosition(fen, ucis) then return nil end
            return think(seconds, maxDepth, yielder)
        end)
        busy = false
        if ok then return res end
        return nil
    end

    return {
        analyse = analyse,
        setPosition = setPosition,
        think = think,
        perft = perft,
        START_FEN = START_FEN,
    }
end)()

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__RoChessStop) == "function" then pcall(Genv.__RoChessStop) end

local Unloaded = false

local S = {
    BotFarm = false,
    Bot = "pebble",
    Color = "random",
    Engine = "Custom",
    MaxDepth = 64,
    ThinkTime = 0.1,
    MoveDelay = 0,
    Requeue = true,
    SolvePuzzles = false,
    NextPuzzle = true,
    SolveRush = false,
    PuzzleThink = 0.1,
    Arrow = false,
    ArrowThink = 0.1,
    ClaimTasks = false,
    AutoCrate = false,
    Crate = "pieces",
    AntiAfk = true,
}

local Stats = { Games = 0, Wins = 0, Draws = 0, Losses = 0, Puzzles = 0, Status = "idle", Eval = "-" }
local Library

local ChessFolder = ReplicatedStorage:WaitForChild("Chess", 30)

local function safeRequire(inst)
    if not inst then return nil end
    local ok, result = pcall(require, inst)
    return ok and result or nil
end

local Engine = safeRequire(ChessFolder and ChessFolder:FindFirstChild("Engine"))
local Bot = safeRequire(ChessFolder and ChessFolder:FindFirstChild("Bot"))
local Config = safeRequire(ChessFolder and ChessFolder:FindFirstChild("Config"))
local Levels = safeRequire(ChessFolder and ChessFolder:FindFirstChild("Levels"))

local App
local function isApp(t)
    return type(t) == "table" and type(rawget(t, "onBoardMove")) == "function"
        and type(rawget(t, "startBotGame")) == "function"
        and type(rawget(t, "endLocalGame")) == "function"
end

local function findApp()
    if isApp(App) then return App end
    if typeof(getgc) == "function" then
        local ok, list = pcall(getgc, true)
        if ok and type(list) == "table" then
            for _, v in ipairs(list) do
                if isApp(v) then App = v return App end
            end
        end
    end
    local client = ReplicatedStorage:FindFirstChild("ChessClient")
    local t = safeRequire(client and client:FindFirstChild("App"))
    if isApp(t) then App = t end
    return App
end

local function session()
    local app = findApp()
    return app and app.session or nil
end

local function onlineLive(s)
    return s ~= nil and s.kind == "online" and not s.over
end

local PROMO = { q = 5, r = 4, b = 3, n = 2 }

local function engineYield()
    task.wait()
end

local function yielderFor(seconds)
    if seconds and seconds > 0.25 then return engineYield end
    return nil
end

local function bestFor(s, seconds)
    if not s or not s.ucis then return nil end
    if S.Engine == "Custom" then
        local res = Brain.analyse(s.startFen, table.clone(s.ucis), seconds, S.MaxDepth, yielderFor(seconds))
        if type(res) == "table" and res.best then return res.best, res end
    end
    if not (Bot and Bot.analyse) then return nil end
    local ok, res = pcall(Bot.analyse, s.startFen, table.clone(s.ucis), seconds, 30)
    if ok and type(res) == "table" then return res.best, res end
    return nil
end

local function playUci(uci)
    local app = findApp()
    if not app or not Engine or type(uci) ~= "string" or #uci < 4 then return false end
    local from = Engine.algToIndex64(uci:sub(1, 2))
    local to = Engine.algToIndex64(uci:sub(3, 4))
    if not from or not to then return false end
    local promo = PROMO[uci:sub(5, 5)]
    local ok, result = pcall(app.onBoardMove, from, to, promo)
    return ok and result ~= false
end

local function myMoveReady(s)
    return s and not s.over and s.viewPly == #s.ucis and type(s.isMyTurn) == "function" and s:isMyTurn()
end

local function describeScore(res)
    if type(res) ~= "table" then return "-" end
    if res.mate then return ("%smate in %d"):format(res.mate < 0 and "-" or "", math.abs(res.mate)) end
    if type(res.score) == "number" then return ("%+.2f"):format(res.score / 100) end
    return "-"
end

local Counted = setmetatable({}, { __mode = "k" })

local function countResult(s)
    if Counted[s] or not s.over or not s.result then return end
    Counted[s] = true
    Stats.Games += 1
    if s.result == "1/2-1/2" then
        Stats.Draws += 1
    elseif (s.result == "1-0") == (s.myColor == 1) then
        Stats.Wins += 1
    else
        Stats.Losses += 1
    end
end

local function startBotGame()
    local app = findApp()
    if not app then return end
    local s = app.session
    if onlineLive(s) or app.searching then return end
    local color = S.Color ~= "random" and S.Color or nil
    pcall(app.startBotGame, S.Bot, color)
end

task.spawn(function()
    local lastEnd
    while not Unloaded do
        if S.BotFarm then
            local s = session()
            if s and s.kind == "bot" then
                if s.over then
                    countResult(s)
                    lastEnd = lastEnd or os.clock()
                    if S.Requeue and os.clock() - lastEnd > 2 then
                        lastEnd = nil
                        Stats.Status = "starting next game"
                        startBotGame()
                    end
                elseif myMoveReady(s) then
                    Stats.Status = "thinking"
                    local best = bestFor(s, S.ThinkTime)
                    if best and session() == s and myMoveReady(s) then
                        if S.MoveDelay > 0 then task.wait(S.MoveDelay) end
                        if session() == s and myMoveReady(s) then
                            playUci(best)
                            Stats.Status = "played " .. best
                        end
                    end
                else
                    Stats.Status = "bot is thinking"
                end
            elseif not onlineLive(s) then
                Stats.Status = "starting a bot game"
                startBotGame()
                task.wait(1.5)
            else
                Stats.Status = "online game open: farm paused"
            end
        end
        task.wait(0.05)
    end
end)

local function puzzleMove(s)
    local pz = s.pz
    local known = pz and pz.sol and pz.sol[pz.step]
    if type(known) == "string" and Engine then
        local probe = Engine.new(s.startFen)
        local legal = true
        for _, u in ipairs(s.ucis) do
            local mv = probe:moveFromUci(u)
            if not mv then legal = false break end
            probe:makeMove(mv)
        end
        if legal and probe:moveFromUci(known) then return known end
    end
    return (bestFor(s, S.PuzzleThink))
end

local function nextPuzzle()
    local app = findApp()
    if not app or app.inLiveGame() then return end
    pcall(app.goHome)
    task.wait(0.3)
    pcall(app.openPuzzles)
end

task.spawn(function()
    local solvedAt
    while not Unloaded do
        local s = session()
        local kind = s and s.kind
        if (kind == "puzzle" and S.SolvePuzzles) or (kind == "rush" and S.SolveRush) then
            local pz = s.pz
            if pz and (pz.done or pz.wrong) then
                if not pz.__counted then
                    pz.__counted = true
                    if pz.outcome == "solved" then Stats.Puzzles += 1 end
                end
                if kind == "puzzle" and S.NextPuzzle then
                    solvedAt = solvedAt or os.clock()
                    if os.clock() - solvedAt > 1.2 then
                        solvedAt = nil
                        nextPuzzle()
                    end
                end
            elseif pz and not pz.busy and not pz.wrong and myMoveReady(s) then
                local mv = puzzleMove(s)
                if mv and session() == s and not pz.busy and myMoveReady(s) then
                    playUci(mv)
                end
            end
        elseif kind ~= "puzzle" then
            solvedAt = nil
        end
        task.wait(0.05)
    end
end)

local ARROW_KINDS = { bot = true, puzzle = true, rush = true, analysis = true }
local ArrowShown = false

local function clearArrow()
    local app = findApp()
    if ArrowShown and app and app.board then pcall(app.board.setArrow, app.board, "hint", nil) end
    ArrowShown = false
end

task.spawn(function()
    local lastKey
    while not Unloaded do
        local s = session()
        if S.Arrow and s and ARROW_KINDS[s.kind] and not s.over and Engine then
            local key = tostring(s) .. ":" .. #s.ucis
            if key ~= lastKey then
                lastKey = key
                local best, res = bestFor(s, S.ArrowThink)
                local app = findApp()
                if best and app and app.board and session() == s and #s.ucis == tonumber(key:match(":(%d+)$")) then
                    local from = Engine.algToIndex64(best:sub(1, 2))
                    local to = Engine.algToIndex64(best:sub(3, 4))
                    pcall(app.board.setArrow, app.board, "hint", from, to, Color3.fromRGB(90, 170, 255), 0.15)
                    ArrowShown = true
                    Stats.Eval = best .. "  (" .. describeScore(res) .. ")"
                end
            end
        else
            lastKey = nil
            if ArrowShown then clearArrow() end
            if s and s.kind == "online" then Stats.Eval = "off in online games" end
        end
        task.wait(0.05)
    end
end)

local TASK_IDS = { "play", "win", "capture" }
if Config and type(Config.DAILY_TASKS) == "table" then
    TASK_IDS = {}
    for _, t in ipairs(Config.DAILY_TASKS) do TASK_IDS[#TASK_IDS + 1] = t.id end
end

local function request(payload)
    local app = findApp()
    if not app or type(app.request) ~= "function" then return nil end
    local ok, res = pcall(app.request, payload)
    return ok and res or nil
end

local function claimTasks()
    for _, id in ipairs(TASK_IDS) do request({ type = "claimTask", id = id }) end
end

task.spawn(function()
    while not Unloaded do
        if S.ClaimTasks then claimTasks() end
        task.wait(30)
    end
end)

local function codesFromNote()
    local note = ChessFolder and ChessFolder:GetAttribute("CodesNote")
    local found = {}
    if type(note) == "string" then
        for word in note:gmatch("%f[%w][%u%d]+%f[%W]") do
            if #word >= 5 and word:find("%u") then found[#found + 1] = word end
        end
    end
    return found
end

local function redeem(code)
    if type(code) ~= "string" or code == "" then return nil end
    return request({ type = "redeemCode", code = code })
end

local CRATES = { "pieces", "board", "effect", "background", "accessory", "halloween" }

task.spawn(function()
    while not Unloaded do
        if S.AutoCrate then
            local res = request({ type = "openCrate", crate = S.Crate })
            if type(res) ~= "table" or not res.ok then S.AutoCrate = false end
        end
        task.wait(3)
    end
end)

local IdleOff = {}
local function setAntiAfk(on)
    if typeof(getconnections) ~= "function" then return false end
    local ok, list = pcall(getconnections, LocalPlayer.Idled)
    if not ok or type(list) ~= "table" then return false end
    if on then
        for _, c in ipairs(list) do pcall(function() c:Disable() IdleOff[#IdleOff + 1] = c end) end
    else
        for _, c in ipairs(IdleOff) do pcall(function() c:Enable() end) end
        table.clear(IdleOff)
    end
    return true
end
task.delay(3, function() if S.AntiAfk and not Unloaded then setAntiAfk(true) end end)

local function unload()
    if Unloaded then return end
    Unloaded = true
    pcall(setAntiAfk, false)
    pcall(clearArrow)
end

Genv.__RoChessStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

local okLib, lib = pcall(function()
    return loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()
end)
if not okLib or type(lib) ~= "table" then return end
Library = lib

local Window = Library:CreateWindow({
    Title = 'RoChess',
    Footer = 'custom engine vs bots',
    Icon = 'crown',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'RoChess',
})

Library:OnUnload(unload)

local function every(interval, fn)
    task.spawn(function()
        while not Unloaded and not Library.Unloaded do
            pcall(fn)
            task.wait(interval)
        end
    end)
end

local function toggle(box, id, text, key, tooltip, onChange)
    return box:AddToggle(id, {
        Text = text,
        Tooltip = tooltip,
        Default = S[key],
        Callback = function(v)
            S[key] = v
            if onChange then onChange(v) end
        end,
    })
end

local BOT_NAMES, BOT_BY_LABEL, BOT_DEFAULT = {}, {}, nil
for _, b in ipairs(Config and Config.BOTS or {}) do
    local label = ("%s (%d)"):format(b.name or b.id, b.rating or 0)
    BOT_NAMES[#BOT_NAMES + 1] = label
    BOT_BY_LABEL[label] = b.id
    if b.id == S.Bot then BOT_DEFAULT = label end
end

do
    local Tab = Window:AddTab('Bots', 'bot', 'Engine plays the bots for XP')

    local overview = Tab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('rc_cards', {
        Cards = {
            { Title = 'Level', Value = '-', Icon = 'star' },
            { Title = 'Wins', Value = '0', Icon = 'trophy' },
            { Title = 'Games', Value = '0', Icon = 'swords' },
            { Title = 'Puzzles', Value = '0', Icon = 'puzzle' },
        },
    })
    local info = overview:AddLabel('-', true)
    every(0.5, function()
        local app = findApp()
        local profile = app and app.profile
        local xp = profile and tonumber(profile.xp)
        if xp and Levels and Levels.of then
            local level, into, need = Levels.of(xp)
            cards:SetValue('Level', ("%d  (%d/%d)"):format(level, into, need))
        end
        cards:SetValue('Wins', tostring(Stats.Wins))
        cards:SetValue('Games', ("%d  (%dW %dD %dL)"):format(Stats.Games, Stats.Wins, Stats.Draws, Stats.Losses))
        cards:SetValue('Puzzles', tostring(Stats.Puzzles))
        local s = app and app.session
        info:SetText(("%s\nsession: %s\nengine: %s"):format(
            app and Stats.Status or "waiting for the game to load",
            s and (s.kind .. (s.over and " (over)" or "")) or "none", Stats.Eval))
    end)

    local farm = Tab:AddLeftGroupbox('Bot farm', 'cpu')
    farm:AddLabel('Plays real games against the bot you pick with the engine you choose, then starts the next one. Wins pay 30 XP; levels pay tokens. Give the custom engine more think time for the 1600+ bots.', true)
    toggle(farm, 'rc_farm', 'Auto play vs bot', 'BotFarm', 'starts a bot game, plays your moves, and requeues when it ends')
        :AddKeyPicker('rc_farm_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Bot farm' })
    farm:AddDropdown('rc_bot', {
        Values = BOT_NAMES,
        Default = BOT_DEFAULT or BOT_NAMES[1],
        Text = 'Opponent',
        Callback = function(v) S.Bot = BOT_BY_LABEL[v] or S.Bot end,
    })
    farm:AddDropdown('rc_color', {
        Values = { 'random', 'white', 'black' },
        Default = S.Color,
        Text = 'Play as',
        Callback = function(v) S.Color = v end,
    })
    toggle(farm, 'rc_requeue', 'Start the next game automatically', 'Requeue')

    local engine = Tab:AddRightGroupbox('Engine', 'brain')
    engine:AddDropdown('rc_engine', {
        Values = { 'Custom', 'Game' },
        Default = S.Engine,
        Text = 'Engine',
        Tooltip = 'Custom: built-in alpha-beta engine (PVS, transposition table, null move, LMR, quiescence, tapered eval). Game: the game\'s own Bot.analyse',
        Callback = function(v) S.Engine = v end,
    })
    engine:AddSlider('rc_depth', { Text = 'Max depth (custom)', Min = 1, Max = 64, Default = S.MaxDepth, Rounding = 0, Callback = function(v) S.MaxDepth = v end })
    engine:AddSlider('rc_think', { Text = 'Think time', Tooltip = 'longer is stronger; weak bots need very little', Min = 0.05, Max = 10, Default = S.ThinkTime, Rounding = 2, Suffix = 's', Callback = function(v) S.ThinkTime = v end })
    engine:AddSlider('rc_delay', { Text = 'Extra delay per move', Min = 0, Max = 3, Default = S.MoveDelay, Rounding = 2, Suffix = 's', Callback = function(v) S.MoveDelay = v end })
    engine:AddButton({ Text = 'Start bot game now', Func = function() task.spawn(startBotGame) end })
    engine:AddButton({
        Text = 'Play best move once',
        Func = function()
            task.spawn(function()
                local s = session()
                if s and s.kind ~= "online" and myMoveReady(s) then
                    local best = bestFor(s, S.ThinkTime)
                    if best then playUci(best) end
                end
            end)
        end,
    })
end

do
    local Tab = Window:AddTab('Puzzles', 'puzzle', 'Puzzle and sprint solver')

    local pz = Tab:AddLeftGroupbox('Puzzles', 'puzzle')
    toggle(pz, 'rc_puzzles', 'Auto solve puzzles', 'SolvePuzzles', 'plays the puzzle\'s solution, or the engine\'s move where the server hasn\'t sent it yet')
    toggle(pz, 'rc_nextpz', 'Load the next puzzle', 'NextPuzzle')
    pz:AddButton({ Text = 'Open puzzles', Func = function() local app = findApp() if app then pcall(app.openPuzzles) end end })
    pz:AddSlider('rc_pzthink', { Text = 'Engine time (rated puzzles)', Min = 0.05, Max = 10, Default = S.PuzzleThink, Rounding = 2, Suffix = 's', Callback = function(v) S.PuzzleThink = v end })

    local rush = Tab:AddRightGroupbox('Puzzle sprint', 'zap')
    rush:AddLabel('Open the sprint page and press Start; this solves each puzzle as it appears.', true)
    toggle(rush, 'rc_rush', 'Auto solve sprint', 'SolveRush')
    rush:AddButton({ Text = 'Open sprint', Func = function() local app = findApp() if app then pcall(app.openRush) end end })
end

do
    local Tab = Window:AddTab('Assist', 'lightbulb', 'Best-move arrow')

    local box = Tab:AddLeftGroupbox('Best move', 'arrow-up-right')
    box:AddLabel('Draws the engine\'s best move on the board in bot games, puzzles and the analysis board. Off in live online games we will be adding online next update :)', true)
    toggle(box, 'rc_arrow', 'Best-move arrow', 'Arrow', nil, function(v) if not v then clearArrow() end end)
    box:AddSlider('rc_arrowthink', { Text = 'Think time', Min = 0.05, Max = 10, Default = S.ArrowThink, Rounding = 2, Suffix = 's', Callback = function(v) S.ArrowThink = v end })
    local eval = box:AddLabel('-', true)
    every(0.5, function() eval:SetText('best: ' .. Stats.Eval) end)
end

do
    local Tab = Window:AddTab('Rewards', 'gift', 'Tasks, codes, crates')

    local tasks = Tab:AddLeftGroupbox('Daily tasks', 'list-checks')
    toggle(tasks, 'rc_tasks', 'Auto claim tasks', 'ClaimTasks', 'claims play / win / capture rewards as they finish (the bot farm completes them)', function(v) if v then task.spawn(claimTasks) end end)
    tasks:AddButton({ Text = 'Claim now', Func = function() task.spawn(claimTasks) end })

    local codes = Tab:AddRightGroupbox('Codes', 'ticket')
    local codeResult = codes:AddLabel('', true)
    codes:AddButton({
        Text = 'Redeem codes from the game',
        Func = function()
            task.spawn(function()
                local list = codesFromNote()
                if #list == 0 then codeResult:SetText('no code in the game\'s note right now') return end
                local out = {}
                for _, c in ipairs(list) do
                    local res = redeem(c)
                    out[#out + 1] = c .. ': ' .. (type(res) == "table" and (res.ok and 'ok' or tostring(res.error or res.msg or 'refused')) or 'no reply')
                end
                codeResult:SetText(table.concat(out, '\n'))
            end)
        end,
    })
    local typed = ''
    codes:AddInput('rc_code', { Text = 'Code', Default = '', Placeholder = 'type a code', Callback = function(v) typed = v end })
    codes:AddButton({
        Text = 'Redeem typed code',
        Func = function()
            task.spawn(function()
                local res = redeem(typed)
                codeResult:SetText(typed .. ': ' .. (type(res) == "table" and (res.ok and 'ok' or tostring(res.error or res.msg or 'refused')) or 'no reply'))
            end)
        end,
    })

    local crates = Tab:AddLeftGroupbox('Crates', 'package')
    crates:AddLabel('Spends tokens (10 per crate). Stops on its own when you run out.', true)
    crates:AddDropdown('rc_crate', { Values = CRATES, Default = S.Crate, Text = 'Crate', Callback = function(v) S.Crate = v end })
    toggle(crates, 'rc_autocrate', 'Auto open crates', 'AutoCrate')

    local idle = Tab:AddRightGroupbox('Idle', 'clock')
    idle:AddToggle('rc_afk', {
        Text = 'Anti-AFK',
        Tooltip = 'stops the 20 minute idle kick while the farm runs',
        Default = S.AntiAfk,
        Callback = function(v) S.AntiAfk = v setAntiAfk(v) end,
    })
end
