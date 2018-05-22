aesim
=====

Æternity p2p simulator

Build
-----

    $ rebar3 escriptize

Run
---

    $ _build/default/bin/aesim

Arguments
---------

When running a scenario, all the possible options are printed before running
the simulation. The options can be changed with:

    $ _build/default/bin/aesim max_sim_time=5h max_nodes=200

### Time Arguments

Format: `[DDd][HHh][MMm][SSs][XXXX]`

e.g.
  - `100`: 100 milliseconds
  - `1h`: 3600000 milliseconds
  - `2m10s42` : 130042 milliseconds

Simulation Scenarios
--------------------

Simulation scenarios are callback modules implementing behaviour
`aesim_scenario`; A scenario different from the default one can be selected
by setting the `scenario_mod` option:

    $ _build/default/bin/aesim scenario_mod=esim_scenario_myscenario
