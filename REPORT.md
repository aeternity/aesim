Simulation Report
=================

The current protocol is considered to be 0.14.0.

Current Protocol
----------------

### Protocol Description

* Connect to all trusted nodes.
* Start pinging all outbound connections.
* Send a new ping 2 minutes after a ping response is received.
* Send up to 32 random peers in each ping.
* Respond to all pings with 32 random peers excluding the received ones.
* Add all gossiped peers to the pool and connect to them.
* Accept all inbound connections.
* Add the peer that connects to the node to the pool only after receiving the
first ping (when we get its full address).
* No limitation on the number of inbound/outbound connections.

Possible divergences from current epoch protocol:

* Connections are not retried individually, the pool is the one selecting
the connection and handling the exponential backoff.
* Because there is no simulation of the synchronization protocol the ping
messages are always sent by the node initiating the connection and this never
change during the life of the connection.

### Simple Simulation

This simulation runs for a fixed amount of simulated time (3 hours).
It first bootstraps a cluster of 3 nodes; two of them are marked as trusted
and used to start later nodes.
It then proceeds to start a new node every 30 seconds up to 300 nodes.

#### Command line

  `aesim max_sim_time=3h max_nodes=300 rrd_enabled=true`

#### Results

The [report](report/current/simple/report.txt) and
[metrics](report/current/simple/metrics/metrics.md) can be consulted in the
`report/current/simple` directory.

##### Number of Connection per Node

The main issue with the protocol is the unbound number of connection.
All the nodes quickly end up connecting to all the other nodes; this causes a
very large number of ping/response to be sent.

After the 3 hours of simulation, all the nodes know each other, and all the
nodes are available in the pool of all the nodes.

All these connections mean each node received an average of 12000 ping
messages during these 3 hours of simulation, the rate at the end is around
5 ping messages per second. This number is still in acceptable but not
negligible.

##### Sybil Attack

Because all the nodes connect to all the other ones, it is quite resistant
against Sybil attacks, but the nodes nor remembering the known peers between
restarts make it more sensible to attacks after scheduled or forced restart.

A way to isolate a node would require the attacker to isolate the
attacked node from the trusted nodes when it is restarted, connect to the node
and gossip only compromised nodes.
The attacker would have to keep it isolated from the trusted nodes during the
whole duration of the attack to keep it isolated.
Isolating the attacked node from the trusted nodes could be achieved through DNS
spoofing or DoS of the trusted nodes.

### Cluster Discovery Time

This simulation focus on finding the time required for a new node to know
the majority of the cluster through gossip when joining a cluster.

A cluster of 300 nodes is setup and the scenario waits for all the nodes in the
cluster to know at least 90% of the other nodes.

Then a new node is started and the time for it to know 90% of the cluster is
measured. This operation is repeated 20 times to get a reliable metric.

#### Command line

  `aesim scenario_mod=aesim_scenario_gossip_time max_sim_time=4h max_nodes=320`

#### Results

The [report](report/current/gossip-time/report.txt) can be consulted in the
`report/current/gossip-time` directory.

Because the nodes connect to all the peers they get from gossiping, and every
node sends them a gossip message right away, they discover the full
cluster very fast. The simulation shows that the median time to know 90% of the
cluster is under one second with a maximum of just over 19 seconds.
The connection delay and processing delay of the simulator could probably be
tweaked to get a more realistic result, but it shows that the gossip protocol
is extremely fast.

### Enhancement Proposals

1. Limit the number of connections, at least the outbound ones.

This would reduce greatly the number of connection in a cluster, making it
more scalable reducing load on the trusted nodes.

2. Store the pooled peers between restarts.

Storing the known peers between restart would prevent a restarting node
to completely depend on the trusted node to join the cluster.
Note that if no more precautions are taken, the known peers could be
heavily poisoned with compromised peers, but because the node connects
to all the peers, at least one ought to not be compromised.

Current Protocol With Connection Limitation
-------------------------------------------

### Protocol Description

This is the same protocol as [Current Protocol](#current-protocol) with the
only difference that the number of inbound/outbound connection is limited.

### Simple Simulation

Same as [Current Protocol](#current-protocol) simple simulation with a limit
of 10 outbound connections and 100 inbound connections (soft limit).

#### Command line

  `aesim max_sim_time=3h max_nodes=300 max_outbound=10 soft_max_inbound=100 max_inbound=1000 rrd_enabled=true`

#### Results

The [report](report/limited-connections/simple/report.txt) and
[metrics](report/limited-connections/simple/metrics/metrics.md) can be
consulted in the 'report/current/limited-connections' directory.

##### Distribution of Inbound/Outbound Connections

Even though nodes have a maximum of 10 outbound connections, the trusted nodes
never reach this number. They get at most a couple of outbound connections.

This is due to the fact that all the nodes connect to the trusted nodes, so they
never try to connect to any peers they receive through gossip because they
already have an inbound connection from them.

This could be a major issue if we would relay new blocks only to outbound
connections and use inbound connection only for sync and mempool.

For the same reason, the trusted nodes still end up with a connection to each
node in the cluster, and if we limit the number of incoming connection to
a number lower than the maximum number of node in the cluster, new nodes
wouldn't be able to join the cluster when this limit is reached.

##### Sybil Attack

Limiting the number of outbound connection make the protocol more exposed
to isolation attack. The attacker would only have to prevent the attacked
node from connecting to the trusted nodes and send a single gossip message
with only compromised peers. Because the limit of outbound connection would
be reached, the attacked node would never connect to the trusted nodes and
stay isolated.

### Cluster Discovery Time

Same as [Current Protocol](#current-protocol) cluster discovery time simulation
with a limit of 10 outbound connections and 100 inbound connections (soft
limit).

#### Command line

  `aesim scenario_mod=aesim_scenario_gossip_time max_sim_time=4h max_nodes=320 max_outbound=10 soft_max_inbound=100 max_inbound=1000`

#### Results

The [report](report/limited-connections/gossip-time/report.txt) can be consulted
in the 'report/limited-connections/gossip-time' directory.

Because each node (besides the trusted ones) have a lot fewer connections,
the gossip protocol takes more time to reach the point where a new node knows
90% of the other nodes. The simulation shows that the median time for a node
joining the cluster to know 90% of the cluster is 4 minutes with the maximum
being 4 minutes and 21 seconds.

#### Enhancement Proposal

1. Not connecting to more than one peer from the same gossip source.

This is a partial solution, the attacker could just send gossip message from
multiple compromised nodes.

2. Not connecting to more than one peer from the same address group.

Like Bitcoin reference server, all peers could be categorized into groups
based on the peer address (e.g. IPv4 /16 group), and the node could connect
to only one peer from each group. This would force an attacker to own
compromised nodes from a different address group. Like the previous proposal
this just makes the attack harder, it doesn't prevent it.

3. Have a soft limit on inbound connections.

To prevent all the nodes to be connected to the trusted nodes but still
allow new nodes to join the cluster, the protocol could have a soft limit
on inbound connections. When the limit is reached, any new inbound connection
is closed right after responding to the first ping message.

This would distribute the connections more homogeneously in the cluster
and resolve the issue of the trusted nodes not having enough outbound
connections.

2. Store the pooled peers between restarts.

Like with the current protocol, storing known peer would prevent a restarting
node from depending on the trusted nodes. But a major difference is that
when restarting, it will only connect to a limited number of the peers,
so if they are heavily poisoned by an attacker there is a probability
of the node getting isolated. So with limited outbound connections, special
attention should be taken in preventing the pool to get poisoned.

Current Protocol With Connection Limitation - Smaller Network
---------------------------------------------------------------

### Protocol Description

This is the same protocol as [Current Protocol](#current-protocol) with the
only difference that the number of inbound/outbound connection is limited.

### Simple Simulation

Same as [Current Protocol](#current-protocol) simple simulation with a limit
of 10 outbound connections and 100 inbound connections (soft limit). Also,
maximum number of nodes is set to 100, which is more realistic scenario as
it's unlikely there is more than ~100 nodes (on mainnet or testnet).

#### Command Line

  `aesim max_sim_time=3h max_nodes=100 max_outbound=10 soft_max_inbound=100 max_inbound=1000 rrd_enabled=true`

#### Results

The [report](report/limited-connections/simple2/report.txt) and
[metrics](report/limited-connections/simple2/metrics/metrics.md) can be
consulted in the 'report/limited-connections/simple2' directory.

### Cluster Discovery Time

Same as [Current Protocol](#current-protocol) cluster discovery time simulation
with a limit of 10 outbound connections and 100 inbound connections (soft
limit). The maximum number of nodes is set to 100.

#### Command line

  `aesim scenario_mod=aesim_scenario_gossip_time max_sim_time=4h max_nodes=100 max_outbound=10 soft_max_inbound=100 max_inbound=1000`

#### Results

The [report](report/limited-connections/gossip-time2/report.txt) can be consulted
in the 'report/limited-connections/gossip-time2' directory.

Current Protocol With Connection Limitation - Larger Network
---------------------------------------------------------------

### Protocol Description

This is the same protocol as [Current Protocol](#current-protocol) with the
only difference that the number of inbound/outbound connection is limited.

### Simple Simulation

Same as [Current Protocol](#current-protocol) simple simulation with a limit
of 10 outbound connections and 100 inbound connections (soft limit). The
simulation starts with 1000 nodes, maximum number of nodes is 2000. The most
important aspect of this simulation is connection rejection probability, which
is set to 99% (only 1% of connection attempts succeeds).

#### Command Line

  `aesim max_sim_time=3h bootstrap_size=1000 max_nodes=2000 reject_iprob=99 max_outbound=10 soft_max_inbound=100 max_inbound=1000 rrd_enabled=true`

#### Results

The [report](report/limited-connections/simple3/report.txt) and
[metrics](report/limited-connections/simple3/metrics/metrics.md) can be
consulted in the 'report/limited-connections/simple3' directory.

### Cluster Discovery Time

Same as [Current Protocol](#current-protocol) cluster discovery time simulation
with a limit of 10 outbound connections and 100 inbound connections (soft
limit). The simulation starts with 1000 nodes, maximum number of nodes is 2000
and conenctions rejection probabilty is 99%.

#### Command line

  `aesim scenario_mod=aesim_scenario_gossip_time max_sim_time=4h bootstrap_size=1000 max_nodes=2000 reject_iprob=99 max_outbound=10 soft_max_inbound=100 max_inbound=1000`

#### Results

TODO: simulation timeout.
