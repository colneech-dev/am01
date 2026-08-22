// ============================================================================
// PROPOSED (not applied): openXC7 plan item 3.6 -- router2 thread partitioning
//
// Status: for review. Nothing in this file is compiled or applied. It replaces
// partition_nets() and do_route() in common/router2.cc.
//
// Motivation (measured): v19 ran at 131% CPU on a 6-core box, ~22% utilisation.
// ============================================================================
//
// HOW THE CURRENT CODE WORKS
//
//   9 bins, N = 8:
//     0..3  quadrants          bbox entirely inside one quadrant
//     4,5   horizontal bands   straddles mid_x but fits one side of mid_y
//     6,7   vertical bands     straddles mid_y but fits one side of mid_x
//     8     serial             straddles BOTH midlines
//
//   Executed as three serialised rounds, then serial work:
//     round 1: threads 0..3   join   (4-way)
//     round 2: threads 4,5    join   (2-way)
//     round 3: threads 6,7    join   (2-way)
//     serial : bin 8, then every net that failed in ANY thread
//
//   The exclusion model: thread_test_wire()'s bbox containment is the ONLY
//   mechanism preventing two threads touching the same flat_wires[] entry.
//   There are no locks. Therefore CONCURRENT THREADS MUST HAVE DISJOINT
//   BOUNDING BOXES. (Violating this is what caused the v5-v8 crashes earlier
//   in this campaign: giving retry threads identical full-chip bboxes made
//   thread_test_wire always pass, producing unguarded cross-thread reads.)
//
// WHY ROUNDS 2 AND 3 CANNOT SIMPLY BE MERGED
//
//   Bins 4,5 are full-width horizontal bands; bins 6,7 are full-height
//   vertical bands. Every horizontal band overlaps every vertical band, so
//   they are not disjoint and cannot run concurrently. The three-round
//   structure is a consequence of the exclusion model, not an oversight.
//   Ceiling with perfect binning is therefore ~2-2.5x, not 6x.
//
// WHY "JUST USE MORE BINS" IS WRONG
//
//   Splitting the top level into a finer grid moves the midlines, so MORE
//   nets straddle a boundary and fall into the serial bin. Naive refinement
//   makes things worse, not better.
//
// THE CHANGE PROPOSED HERE, AND WHY IT IS SAFE
//
//   Add a DEEPER level BELOW the existing quadrants: a 4x4 grid of 16
//   sub-quadrants, processed as a new first round. The existing quadrant /
//   band / serial levels are left exactly as they are.
//
//   The key property, and the reason this is worth doing:
//
//       *** Adding a deeper level CANNOT grow the serial bin. ***
//
//   A net only reaches a sub-quadrant bin if its bbox fits entirely inside
//   one sub-quadrant -- in which case it also fits inside a quadrant, so it
//   would have gone to a 4-way bin before and now goes to a 16-way bin. A net
//   that straddles a sub-quadrant line but fits a quadrant still lands in the
//   quadrant bin, exactly as today. A net that straddles both top-level
//   midlines still goes serial, exactly as today.
//
//   So this is strictly-more-parallelism with an identical serial set. The
//   16 sub-quadrants are disjoint by construction, so the exclusion invariant
//   holds.
//
// THE THING THAT MAY MATTER MORE (instrumented below, not yet fixed)
//
//   After the three rounds, do_route() does:
//
//       for (int i = 0; i < N; i++)
//           for (auto fail : tcs.at(i).failed_nets)
//               route_net(tcs.at(N), fail, false);     // SERIAL
//
//   A net routed in a thread whose arc needs to leave that thread's bbox gets
//   ARC_RETRY_WITHOUT_BB, is pushed to failed_nets, and is re-routed SERIALLY
//   here. On a design that fills the chip this population may be far larger
//   than bin 8 -- in which case it, not the binning, is the real serial
//   bottleneck and this whole change buys little.
//
//   We do not currently know that number. Both counters are logged below.
//   MEASURE BEFORE JUDGING THIS CHANGE. If serial-failures dominates, the
//   next move is to make that re-route pass parallel (partition the failed
//   set the same way) rather than to refine the binning further.
//
// Env gate: NEXTPNR_MT_DEEP=1. Unset == exact current behaviour.
// ============================================================================

    int mid_x = 0, mid_y = 0;
    // AM01/openXC7 (3.6): quartile split points. qx[0]=0, qx[4]=INT_MAX, and
    // qx[2] is kept identical to mid_x so the coarse levels are unchanged.
    std::array<int, 5> qx{}, qy{};

    void partition_nets()
    {
        // Create a histogram of positions in X and Y positions
        std::map<int, int> cxs, cys;
        for (auto &n : nets) {
            if (n.cx != -1)
                ++cxs[n.cx];
            if (n.cy != -1)
                ++cys[n.cy];
        }
        // Median split (unchanged -- drives the existing quadrant/band levels)
        int accum_x = 0, accum_y = 0;
        int halfway = int(nets.size()) / 2;
        for (auto &p : cxs) {
            if (accum_x < halfway && (accum_x + p.second) >= halfway)
                mid_x = p.first;
            accum_x += p.second;
        }
        for (auto &p : cys) {
            if (accum_y < halfway && (accum_y + p.second) >= halfway)
                mid_y = p.first;
            accum_y += p.second;
        }

        // AM01/openXC7 (3.6): quartiles for the deeper 4x4 level. Balanced on
        // net COUNT, like the median above. Note this balances count, not
        // work -- a round still costs as long as its slowest thread, so a bin
        // holding a few very expensive nets can dominate. Improving that needs
        // a cost estimate per net; deliberately out of scope here.
        auto quantile = [](const std::map<int, int> &hist, int total, int num, int den) {
            int want = int(int64_t(total) * num / den), accum = 0, result = 0;
            for (auto &p : hist) {
                if (accum < want && (accum + p.second) >= want)
                    result = p.first;
                accum += p.second;
            }
            return result;
        };
        int total = int(nets.size());
        qx[0] = 0;
        qx[1] = quantile(cxs, total, 1, 4);
        qx[2] = mid_x;
        qx[3] = quantile(cxs, total, 3, 4);
        qx[4] = std::numeric_limits<int>::max();
        qy[0] = 0;
        qy[1] = quantile(cys, total, 1, 4);
        qy[2] = mid_y;
        qy[3] = quantile(cys, total, 3, 4);
        qy[4] = std::numeric_limits<int>::max();

        // Degenerate placements can collapse quartiles onto the median; if the
        // ladder is not strictly increasing the deeper level is useless (every
        // net straddles), so disable it rather than build empty bins.
        for (int k = 0; k < 4; k++) {
            if (qx[k] >= qx[k + 1] || qy[k] >= qy[k + 1]) {
                deep_ok = false;
                break;
            }
        }

        if (ctx->verbose) {
            log_info("    x splitpoint: %d\n", mid_x);
            log_info("    y splitpoint: %d\n", mid_y);
            log_info("    x quartiles: %d %d %d\n", qx[1], qx[2], qx[3]);
            log_info("    y quartiles: %d %d %d\n", qy[1], qy[2], qy[3]);
        }
        // ... existing bins[] histogram logging unchanged ...
    }

    bool deep_ok = true;

    void do_route()
    {
        // Don't multithread if fewer than 200 nets (heuristic)
        if (route_queue.size() < 200) {
            ThreadContext st;
            st.rng.rngseed(ctx->rng64());
            st.bb = ArcBounds(0, 0, std::numeric_limits<int>::max(), std::numeric_limits<int>::max());
            for (size_t j = 0; j < route_queue.size(); j++)
                route_net(st, nets_by_udata[route_queue[j]], false);
            return;
        }

        // AM01/openXC7 (3.6), env-gated. Unset => Ns = 0, i.e. bit-identical to
        // the current bin layout and round structure.
        static const bool deep_mt = getenv("NEXTPNR_MT_DEEP") != nullptr;
        const bool use_deep = deep_mt && deep_ok && (std::thread::hardware_concurrency() >= 8);
        const int Ns = use_deep ? 16 : 0;         // sub-quadrants (deepest, most parallel)
        const int Nq = 4, Nv = 2, Nh = 2;
        const int N = Ns + Nq + Nv + Nh;          // index of the serial bin
        std::vector<ThreadContext> tcs(N + 1);
        for (auto &th : tcs)
            th.rng.rngseed(ctx->rng64());

        // ---- bounding boxes ------------------------------------------------
        // Sub-quadrants: disjoint by construction (half-open ladders in x and
        // y), which is what keeps the no-lock exclusion model sound.
        if (use_deep) {
            for (int j = 0; j < 4; j++)
                for (int i = 0; i < 4; i++) {
                    int x1 = (i == 3) ? std::numeric_limits<int>::max() : qx[i + 1] - 1;
                    int y1 = (j == 3) ? std::numeric_limits<int>::max() : qy[j + 1] - 1;
                    tcs.at(j * 4 + i).bb = ArcBounds(qx[i], qy[j], x1, y1);
                }
        }
        const int Q = Ns;                          // first quadrant bin index
        tcs.at(Q + 0).bb = ArcBounds(0, 0, mid_x, mid_y);
        tcs.at(Q + 1).bb = ArcBounds(mid_x + 1, 0, std::numeric_limits<int>::max(), mid_y);
        tcs.at(Q + 2).bb = ArcBounds(0, mid_y + 1, mid_x, std::numeric_limits<int>::max());
        tcs.at(Q + 3).bb =
                ArcBounds(mid_x + 1, mid_y + 1, std::numeric_limits<int>::max(), std::numeric_limits<int>::max());
        const int V = Q + Nq;
        tcs.at(V + 0).bb = ArcBounds(0, 0, std::numeric_limits<int>::max(), mid_y);
        tcs.at(V + 1).bb = ArcBounds(0, mid_y + 1, std::numeric_limits<int>::max(), std::numeric_limits<int>::max());
        const int H = V + Nv;
        tcs.at(H + 0).bb = ArcBounds(0, 0, mid_x, std::numeric_limits<int>::max());
        tcs.at(H + 1).bb = ArcBounds(mid_x + 1, 0, std::numeric_limits<int>::max(), std::numeric_limits<int>::max());
        tcs.at(N).bb = ArcBounds(0, 0, std::numeric_limits<int>::max(), std::numeric_limits<int>::max());

        // ---- bin assignment ------------------------------------------------
        // Deepest fit wins. A net can only land in a sub-quadrant if it would
        // otherwise have landed in a quadrant, so the serial bin is unchanged.
        auto band = [](int lo, int hi, const std::array<int, 5> &q) -> int {
            for (int k = 0; k < 4; k++)
                if (lo >= q[k] && hi < q[k + 1])
                    return k;
            return -1;
        };

        for (auto n : route_queue) {
            auto &nd = nets.at(n);
            auto ni = nets_by_udata.at(n);
            int bin = N;

            if (use_deep) {
                int bi = band(nd.bb.x0, nd.bb.x1, qx);
                int bj = band(nd.bb.y0, nd.bb.y1, qy);
                if (bi >= 0 && bj >= 0) {
                    tcs.at(bj * 4 + bi).route_nets.push_back(ni);
                    continue;
                }
            }
            // Quadrants
            if (nd.bb.x0 < mid_x && nd.bb.x1 < mid_x && nd.bb.y0 < mid_y && nd.bb.y1 < mid_y)
                bin = Q + 0;
            else if (nd.bb.x0 >= mid_x && nd.bb.x1 >= mid_x && nd.bb.y0 < mid_y && nd.bb.y1 < mid_y)
                bin = Q + 1;
            else if (nd.bb.x0 < mid_x && nd.bb.x1 < mid_x && nd.bb.y0 >= mid_y && nd.bb.y1 >= mid_y)
                bin = Q + 2;
            else if (nd.bb.x0 >= mid_x && nd.bb.x1 >= mid_x && nd.bb.y0 >= mid_y && nd.bb.y1 >= mid_y)
                bin = Q + 3;
            // Horizontal bands (straddle mid_x, fit one side of mid_y)
            else if (nd.bb.y0 < mid_y && nd.bb.y1 < mid_y)
                bin = V + 0;
            else if (nd.bb.y0 >= mid_y && nd.bb.y1 >= mid_y)
                bin = V + 1;
            // Vertical bands (straddle mid_y, fit one side of mid_x)
            else if (nd.bb.x0 < mid_x && nd.bb.x1 < mid_x)
                bin = H + 0;
            else if (nd.bb.x0 >= mid_x && nd.bb.x1 >= mid_x)
                bin = H + 1;
            tcs.at(bin).route_nets.push_back(ni);
        }

        log_info("    thread bins: %d/%d nets serial (not multi-threadable)\n", int(tcs.at(N).route_nets.size()),
                 int(route_queue.size()));

        // ---- rounds. Each round's bboxes are mutually disjoint. ------------
        auto run_round = [&](int first, int count) {
            if (count <= 0)
                return;
            std::vector<std::thread> threads;
            for (int i = first; i < first + count; i++)
                threads.emplace_back([this, &tcs, i]() { router_thread(tcs.at(i)); });
            for (auto &t : threads)
                t.join();
        };

        run_round(0, Ns);   // 16-way (new; no-op when disabled)
        run_round(Q, Nq);   // 4-way
        run_round(V, Nv);   // 2-way
        run_round(H, Nh);   // 2-way

        // ---- serial tail ---------------------------------------------------
        for (auto st_net : tcs.at(N).route_nets)
            route_net(tcs.at(N), st_net, false);

        // Nets that failed inside a thread (typically ARC_RETRY_WITHOUT_BB: an
        // arc needed to leave the thread's bbox) are re-routed serially here.
        // THIS MAY BE THE REAL BOTTLENECK -- see the header. Counted so the
        // next run tells us whether 3.6 is worth pursuing further.
        int serial_failures = 0;
        for (int i = 0; i < N; i++)
            serial_failures += int(tcs.at(i).failed_nets.size());
        log_info("    thread bins: %d nets re-routed serially after MT failure\n", serial_failures);

        for (int i = 0; i < N; i++)
            for (auto fail : tcs.at(i).failed_nets)
                route_net(tcs.at(N), fail, false);
    }
