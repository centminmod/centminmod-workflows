#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "mysql-connector-python>=8.0.33",
# ]
# ///

"""
ProxySQL Metrics Analyzer v1.2.0

MySQLTuner-equivalent tool for ProxySQL query digest analysis and cache optimization.
Identifies top SELECT queries for ProxySQL query cache configuration and provides
automated cache rule recommendations.

by George Liu (eva2000) at https://centminmod.com/

Usage:
    uv run proxysql_report.py --host 127.0.0.1 --port 6032 --user admin --password admin
    uv run proxysql_report.py --help
"""

import argparse
import sys
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass
from datetime import datetime

try:
    import mysql.connector
    from mysql.connector import Error
except ImportError:
    print("Error: mysql-connector-python not installed. Run with: uv run proxysql_report.py")
    sys.exit(1)


@dataclass
class QueryDigest:
    """Query digest statistics from ProxySQL"""
    hostgroup: int
    schemaname: str
    username: str
    digest: str
    digest_text: str
    count_star: int
    sum_time: int
    min_time: int
    max_time: int

    @property
    def avg_time(self) -> float:
        """Calculate average execution time in microseconds"""
        return self.sum_time / self.count_star if self.count_star > 0 else 0

    @property
    def cache_score(self) -> float:
        """Calculate cache worthiness score (weighted algorithm)"""
        # Normalize values for scoring
        count_weight = 0.4
        sum_time_weight = 0.3
        avg_time_weight = 0.3

        # Score components (normalized to 0-1000 range)
        count_score = min(self.count_star / 10, 1000) * count_weight
        sum_score = min(self.sum_time / 100000, 1000) * sum_time_weight
        avg_score = min(self.avg_time / 1000, 1000) * avg_time_weight

        return count_score + sum_score + avg_score

    @property
    def is_select(self) -> bool:
        """Check if query is a SELECT statement"""
        return self.digest_text.strip().upper().startswith('SELECT')


@dataclass
class CacheStats:
    """ProxySQL query cache statistics"""
    memory_bytes: int = 0
    entries: int = 0
    count_get: int = 0
    count_get_ok: int = 0
    count_set: int = 0
    bytes_in: int = 0
    bytes_out: int = 0
    purged: int = 0

    @property
    def hit_rate(self) -> float:
        """Calculate cache hit rate percentage"""
        return (self.count_get_ok / self.count_get * 100) if self.count_get > 0 else 0.0


@dataclass
class ConnectionPoolStats:
    """ProxySQL connection pool statistics with efficiency metrics"""
    hostgroup: int
    srv_host: str
    srv_port: int
    status: str
    queries: int
    conn_used: int
    conn_free: int
    bytes_sent: int
    bytes_recv: int
    conn_ok: int = 0        # Successfully established connections
    conn_err: int = 0       # Failed connection attempts
    max_conn_used: int = 0  # Peak connections used
    latency_us: int = 0     # Backend ping latency (microseconds)

    @property
    def total_connections(self) -> int:
        """Total active connections in pool"""
        return self.conn_used + self.conn_free

    @property
    def pool_utilization(self) -> float:
        """Connection pool utilization rate percentage"""
        total = self.total_connections
        return (self.conn_used / total * 100) if total > 0 else 0.0

    @property
    def connection_success_rate(self) -> float:
        """Connection success rate percentage"""
        total_attempts = self.conn_ok + self.conn_err
        return (self.conn_ok / total_attempts * 100) if total_attempts > 0 else 100.0

    @property
    def queries_per_connection(self) -> float:
        """Average queries per successful connection (efficiency metric)"""
        return self.queries / self.conn_ok if self.conn_ok > 0 else 0.0

    @property
    def avg_latency_ms(self) -> float:
        """Average backend latency in milliseconds"""
        return self.latency_us / 1000.0 if self.latency_us > 0 else 0.0

    @property
    def efficiency_score(self) -> float:
        """Overall connection pool efficiency score (0-100)

        Weighted formula:
        - 35% connection success rate
        - 25% pool utilization (capped at 80% optimal)
        - 25% queries per connection efficiency
        - 15% latency performance
        """
        success_weight = self.connection_success_rate * 0.35

        # Cap utilization at 80% (higher can indicate saturation)
        util_pct = min(self.pool_utilization, 80) / 80 * 100
        util_weight = util_pct * 0.25

        # Normalize queries/conn (100+ is excellent)
        qpc_pct = min(self.queries_per_connection / 100, 1) * 100
        qpc_weight = qpc_pct * 0.25

        # Latency scoring: reward <2ms, penalize >5ms
        if self.avg_latency_ms <= 2:
            latency_score = 100
        elif self.avg_latency_ms <= 5:
            latency_score = 80
        elif self.avg_latency_ms <= 10:
            latency_score = 50
        else:
            latency_score = max(0, 100 - (self.avg_latency_ms - 10) * 5)
        latency_weight = latency_score * 0.15

        return success_weight + util_weight + qpc_weight + latency_weight


@dataclass
class HealthCheckStats:
    """Backend health check monitoring statistics"""
    check_type: str  # 'ping' or 'connect'
    hostname: str
    port: int
    total_checks: int
    failed_checks: int
    avg_time_us: int
    last_error: Optional[str] = None

    @property
    def success_rate(self) -> float:
        """Health check success rate percentage"""
        return ((self.total_checks - self.failed_checks) / self.total_checks * 100) if self.total_checks > 0 else 0.0

    @property
    def avg_time_ms(self) -> float:
        """Average check time in milliseconds"""
        return self.avg_time_us / 1000.0 if self.avg_time_us > 0 else 0.0


@dataclass
class GlobalStats:
    """ProxySQL global performance statistics"""
    uptime_seconds: int = 0
    client_connections_connected: int = 0
    server_connections_created: int = 0
    queries_total: int = 0
    slow_queries: int = 0
    active_transactions: int = 0

    @property
    def uptime_formatted(self) -> str:
        """Format uptime as human-readable string"""
        hours, remainder = divmod(self.uptime_seconds, 3600)
        minutes, seconds = divmod(remainder, 60)
        return f"{hours}h {minutes}m {seconds}s"

    @property
    def multiplexing_ratio(self) -> float:
        """Frontend to backend connection multiplexing ratio

        High ratio (>10x) indicates excellent connection pooling efficiency.
        ProxySQL excels at N client connections → M backend connections where N >> M
        """
        return self.client_connections_connected / self.server_connections_created if self.server_connections_created > 0 else 0.0

    @property
    def slow_query_rate(self) -> float:
        """Slow query rate as percentage of total queries"""
        return (self.slow_queries / self.queries_total * 100) if self.queries_total > 0 else 0.0


@dataclass
class FreeConnectionStats:
    """Individual free connection in pool"""
    fd: int                    # File descriptor
    hostgroup: int
    srv_host: str
    srv_port: int
    user: str
    schema: str
    idle_ms: int

    @property
    def idle_seconds(self) -> float:
        """Idle time in seconds"""
        return self.idle_ms / 1000.0

    @property
    def is_stale(self) -> bool:
        """Connection idle > 5 minutes (potential leak)"""
        return self.idle_ms > 300000


@dataclass
class FreeConnectionSummary:
    """Aggregated free connection metrics"""
    total_free: int = 0
    total_stale: int = 0        # Idle > 5 min
    avg_idle_ms: float = 0.0
    max_idle_ms: int = 0
    connections_by_hostgroup: Dict[int, int] = None
    connections_by_user: Dict[str, int] = None

    def __post_init__(self):
        if self.connections_by_hostgroup is None:
            self.connections_by_hostgroup = {}
        if self.connections_by_user is None:
            self.connections_by_user = {}

    @property
    def stale_percentage(self) -> float:
        """Percentage of connections that are stale"""
        return (self.total_stale / self.total_free * 100) if self.total_free > 0 else 0.0

    @property
    def max_idle_minutes(self) -> float:
        """Max idle time in minutes"""
        return self.max_idle_ms / 60000.0


@dataclass
class MemoryMetrics:
    """ProxySQL memory usage metrics"""
    jemalloc_allocated: int = 0    # Bytes allocated by jemalloc
    jemalloc_resident: int = 0     # Resident memory (RSS)
    jemalloc_active: int = 0       # Active allocations
    auth_memory: int = 0           # Authentication cache memory
    sqlite3_memory_bytes: int = 0  # SQLite memory usage
    query_digest_memory: int = 0   # Query digest cache memory
    stack_memory_mysql_threads: int = 0
    stack_memory_admin_threads: int = 0

    @property
    def jemalloc_allocated_mb(self) -> float:
        """Allocated memory in MB"""
        return self.jemalloc_allocated / (1024 * 1024)

    @property
    def jemalloc_resident_mb(self) -> float:
        """Resident memory in MB"""
        return self.jemalloc_resident / (1024 * 1024)

    @property
    def total_stack_memory_mb(self) -> float:
        """Total thread stack memory in MB"""
        return (self.stack_memory_mysql_threads + self.stack_memory_admin_threads) / (1024 * 1024)

    @property
    def query_digest_memory_mb(self) -> float:
        """Query digest memory in MB"""
        return self.query_digest_memory / (1024 * 1024)

    @property
    def memory_overhead_pct(self) -> float:
        """Memory overhead: resident vs allocated"""
        return ((self.jemalloc_resident - self.jemalloc_allocated) / self.jemalloc_allocated * 100) if self.jemalloc_allocated > 0 else 0.0


class ProxySQLAnalyzer:
    """ProxySQL metrics analyzer - MySQLTuner equivalent for ProxySQL"""

    VERSION = "1.2.0"

    def __init__(self, host: str, port: int, user: str, password: str):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.conn: Optional[mysql.connector.connection.MySQLConnection] = None

    def connect(self) -> bool:
        """Connect to ProxySQL admin interface"""
        try:
            self.conn = mysql.connector.connect(
                host=self.host,
                port=self.port,
                user=self.user,
                password=self.password,
                connection_timeout=10
            )
            return self.conn.is_connected()
        except Error as e:
            print(f"✗  Connection failed: {e}")
            return False

    def close(self):
        """Close database connection"""
        if self.conn and self.conn.is_connected():
            self.conn.close()

    def execute_query(self, query: str) -> List[Tuple]:
        """Execute SQL query and return results"""
        if not self.conn or not self.conn.is_connected():
            return []

        try:
            cursor = self.conn.cursor()
            cursor.execute(query)
            results = cursor.fetchall()
            cursor.close()
            return results
        except Error as e:
            print(f"Query error: {e}")
            return []

    def get_proxysql_version(self) -> str:
        """Get ProxySQL version"""
        result = self.execute_query("SELECT @@version")
        return result[0][0] if result else "Unknown"

    def get_query_digest(self, limit: int = 100) -> List[QueryDigest]:
        """Fetch query digest statistics"""
        query = f"""
        SELECT hostgroup, schemaname, username, digest, digest_text,
               count_star, sum_time, min_time, max_time
        FROM stats_mysql_query_digest
        WHERE count_star >= 10
        ORDER BY sum_time DESC
        LIMIT {limit}
        """

        results = self.execute_query(query)
        return [
            QueryDigest(
                hostgroup=int(row[0]) if str(row[0]).isdigit() else 0,
                schemaname=str(row[1]),
                username=str(row[2]),
                digest=str(row[3]),
                digest_text=str(row[4]),
                count_star=int(row[5]) if str(row[5]).isdigit() else 0,
                sum_time=int(row[6]) if str(row[6]).isdigit() else 0,
                min_time=int(row[7]) if str(row[7]).isdigit() else 0,
                max_time=int(row[8]) if str(row[8]).isdigit() else 0
            )
            for row in results
        ]

    def get_cache_stats(self) -> CacheStats:
        """Fetch query cache statistics"""
        query = """
        SELECT Variable_name, Variable_Value
        FROM stats_mysql_global
        WHERE Variable_name LIKE 'Query_Cache%'
        """

        results = self.execute_query(query)
        stats = CacheStats()

        for var_name, var_value in results:
            value = int(var_value) if var_value.isdigit() else 0
            if 'Memory_bytes' in var_name:
                stats.memory_bytes = value
            elif 'Entries' in var_name:
                stats.entries = value
            elif 'count_GET_OK' in var_name:
                stats.count_get_ok = value
            elif 'count_GET' in var_name:
                stats.count_get = value
            elif 'count_SET' in var_name:
                stats.count_set = value
            elif 'bytes_IN' in var_name:
                stats.bytes_in = value
            elif 'bytes_OUT' in var_name:
                stats.bytes_out = value
            elif 'Purged' in var_name:
                stats.purged = value

        return stats

    def get_extended_connection_pool_stats(self) -> List[ConnectionPoolStats]:
        """Fetch extended connection pool statistics with efficiency metrics"""
        query = """
        SELECT hostgroup, srv_host, srv_port, status, Queries,
               ConnUsed, ConnFree, Bytes_data_sent, Bytes_data_recv,
               ConnOK, ConnERR, MaxConnUsed, Latency_us
        FROM stats_mysql_connection_pool
        """

        results = self.execute_query(query)
        pool_stats = []
        for row in results:
            pool_stats.append(ConnectionPoolStats(
                hostgroup=int(row[0]) if str(row[0]).isdigit() else 0,
                srv_host=str(row[1]),
                srv_port=int(row[2]) if str(row[2]).isdigit() else 0,
                status=str(row[3]),
                queries=int(row[4]) if str(row[4]).isdigit() else 0,
                conn_used=int(row[5]) if str(row[5]).isdigit() else 0,
                conn_free=int(row[6]) if str(row[6]).isdigit() else 0,
                bytes_sent=int(row[7]) if str(row[7]).isdigit() else 0,
                bytes_recv=int(row[8]) if str(row[8]).isdigit() else 0,
                conn_ok=int(row[9]) if str(row[9]).isdigit() else 0,
                conn_err=int(row[10]) if str(row[10]).isdigit() else 0,
                max_conn_used=int(row[11]) if str(row[11]).isdigit() else 0,
                latency_us=int(row[12]) if str(row[12]).isdigit() else 0
            ))
        return pool_stats

    def get_command_counters(self) -> List[Tuple[str, int, int]]:
        """Fetch command counter statistics"""
        query = """
        SELECT Command, Total_cnt, Total_Time_us
        FROM stats_mysql_commands_counters
        WHERE Total_cnt > 0
        ORDER BY Total_cnt DESC
        LIMIT 10
        """

        results = self.execute_query(query)
        return [
            (str(row[0]),
             int(row[1]) if str(row[1]).isdigit() else 0,
             int(row[2]) if str(row[2]).isdigit() else 0)
            for row in results
        ]

    def get_cache_config(self) -> Dict[str, str]:
        """Fetch cache configuration variables"""
        query = """
        SELECT variable_name, variable_value
        FROM global_variables
        WHERE variable_name LIKE '%cache%'
        ORDER BY variable_name
        """

        results = self.execute_query(query)
        return {name: value for name, value in results}

    def get_monitor_config(self) -> Dict[str, str]:
        """Fetch monitor configuration variables"""
        query = """
        SELECT variable_name, variable_value
        FROM global_variables
        WHERE variable_name LIKE 'mysql-monitor%'
        ORDER BY variable_name
        """

        results = self.execute_query(query)
        return {name: value for name, value in results}

    def get_existing_cache_rules(self) -> List[Tuple[int, str, int]]:
        """Fetch existing cache rules"""
        query = """
        SELECT rule_id, match_pattern, cache_ttl
        FROM mysql_query_rules
        WHERE cache_ttl > 0
        ORDER BY rule_id
        """

        results = self.execute_query(query)
        return [
            (int(row[0]) if str(row[0]).isdigit() else 0,
             str(row[1]),
             int(row[2]) if str(row[2]).isdigit() else 0)
            for row in results
        ]

    def get_global_stats(self) -> GlobalStats:
        """Fetch ProxySQL global performance statistics"""
        query = """
        SELECT Variable_name, Variable_Value
        FROM stats_mysql_global
        WHERE Variable_name IN (
            'ProxySQL_Uptime',
            'Client_Connections_connected',
            'Server_Connections_created',
            'Questions',
            'Slow_queries',
            'Active_Transactions'
        )
        """

        results = self.execute_query(query)
        stats = GlobalStats()

        for var_name, var_value in results:
            value = int(var_value) if var_value.isdigit() else 0
            if 'Uptime' in var_name:
                stats.uptime_seconds = value
            elif 'Client_Connections_connected' in var_name:
                stats.client_connections_connected = value
            elif 'Server_Connections_created' in var_name:
                stats.server_connections_created = value
            elif 'Questions' in var_name:
                stats.queries_total = value
            elif 'Slow_queries' in var_name:
                stats.slow_queries = value
            elif 'Active_Transactions' in var_name:
                stats.active_transactions = value

        return stats

    def get_health_checks(self) -> Tuple[List[HealthCheckStats], List[HealthCheckStats]]:
        """Fetch backend health check statistics (ping and connect)

        Returns: (ping_checks, connect_checks)
        """
        # Ping checks (last 5 minutes)
        ping_query = """
        SELECT 'ping' as check_type, hostname, port,
               COUNT(*) as total_checks,
               SUM(CASE WHEN ping_error IS NOT NULL THEN 1 ELSE 0 END) as failed_checks,
               COALESCE(AVG(CASE WHEN ping_success_time_us > 0 THEN ping_success_time_us ELSE NULL END), 0) as avg_time_us
        FROM monitor.mysql_server_ping_log
        WHERE time_start_us > (strftime('%s', 'now') - 300) * 1000000
        GROUP BY hostname, port
        """

        # Connect checks (last 5 minutes)
        connect_query = """
        SELECT 'connect' as check_type, hostname, port,
               COUNT(*) as total_checks,
               SUM(CASE WHEN connect_error IS NOT NULL THEN 1 ELSE 0 END) as failed_checks,
               COALESCE(AVG(CASE WHEN connect_success_time_us > 0 THEN connect_success_time_us ELSE NULL END), 0) as avg_time_us,
               MAX(connect_error) as last_error
        FROM monitor.mysql_server_connect_log
        WHERE time_start_us > (strftime('%s', 'now') - 300) * 1000000
        GROUP BY hostname, port
        """

        ping_results = self.execute_query(ping_query)
        connect_results = self.execute_query(connect_query)

        ping_checks = []
        for row in ping_results:
            ping_checks.append(HealthCheckStats(
                check_type=str(row[0]),
                hostname=str(row[1]),
                port=int(row[2]) if str(row[2]).isdigit() else 0,
                total_checks=int(row[3]) if str(row[3]).isdigit() else 0,
                failed_checks=int(row[4]) if str(row[4]).isdigit() else 0,
                avg_time_us=int(float(row[5])) if row[5] else 0
            ))

        connect_checks = []
        for row in connect_results:
            # Handle last_error which is optional (7th field)
            last_error = str(row[6]) if len(row) > 6 and row[6] else None
            connect_checks.append(HealthCheckStats(
                check_type=str(row[0]),
                hostname=str(row[1]),
                port=int(row[2]) if str(row[2]).isdigit() else 0,
                total_checks=int(row[3]) if str(row[3]).isdigit() else 0,
                failed_checks=int(row[4]) if str(row[4]).isdigit() else 0,
                avg_time_us=int(float(row[5])) if row[5] else 0,
                last_error=last_error
            ))

        return ping_checks, connect_checks

    def get_free_connections(self) -> FreeConnectionSummary:
        """Fetch and analyze free connection statistics"""
        query = """
        SELECT fd, hostgroup, srv_host, srv_port, user,
               COALESCE(schema, '') as schema, idle_ms
        FROM stats_mysql_free_connections
        ORDER BY idle_ms DESC
        """

        results = self.execute_query(query)

        connections = []
        by_hostgroup = {}
        by_user = {}
        total_idle_ms = 0
        max_idle = 0
        stale_count = 0

        for row in results:
            fd = int(row[0])
            hostgroup = int(row[1])
            srv_host = str(row[2])
            srv_port = int(row[3])
            user = str(row[4])
            schema = str(row[5]) if row[5] else ''
            idle_ms = int(row[6]) if str(row[6]).isdigit() else 0

            conn = FreeConnectionStats(
                fd=fd,
                hostgroup=hostgroup,
                srv_host=srv_host,
                srv_port=srv_port,
                user=user,
                schema=schema,
                idle_ms=idle_ms
            )

            connections.append(conn)
            total_idle_ms += idle_ms
            max_idle = max(max_idle, idle_ms)

            if conn.is_stale:
                stale_count += 1

            # Aggregate by hostgroup
            by_hostgroup[hostgroup] = by_hostgroup.get(hostgroup, 0) + 1

            # Aggregate by user
            by_user[user] = by_user.get(user, 0) + 1

        total_connections = len(connections)
        avg_idle = total_idle_ms / total_connections if total_connections > 0 else 0

        return FreeConnectionSummary(
            total_free=total_connections,
            total_stale=stale_count,
            avg_idle_ms=avg_idle,
            max_idle_ms=max_idle,
            connections_by_hostgroup=by_hostgroup,
            connections_by_user=by_user
        )

    def get_memory_metrics(self) -> MemoryMetrics:
        """Fetch ProxySQL memory usage metrics"""
        query = """
        SELECT Variable_Name, Variable_Value
        FROM stats_memory_metrics
        """

        results = self.execute_query(query)
        metrics = MemoryMetrics()

        for var_name, var_value in results:
            value = int(var_value) if str(var_value).isdigit() else 0

            var_lower = var_name.lower()

            if 'jemalloc_allocated' in var_lower:
                metrics.jemalloc_allocated = value
            elif 'jemalloc_resident' in var_lower:
                metrics.jemalloc_resident = value
            elif 'jemalloc_active' in var_lower:
                metrics.jemalloc_active = value
            elif 'auth_memory' in var_lower:
                metrics.auth_memory = value
            elif 'sqlite3_memory_bytes' in var_lower:
                metrics.sqlite3_memory_bytes = value
            elif 'query_digest_memory' in var_lower:
                metrics.query_digest_memory = value
            elif 'stack_memory_mysql_threads' in var_lower:
                metrics.stack_memory_mysql_threads = value
            elif 'stack_memory_admin_threads' in var_lower:
                metrics.stack_memory_admin_threads = value

        return metrics

    def suggest_ttl(self, count_star: int, avg_time: float) -> int:
        """Suggest appropriate TTL based on query frequency and execution time"""
        # High-frequency queries (>100/sec equivalent in our test window)
        if count_star > 100:
            return 5000  # 5 seconds
        # Medium-frequency (10-100 executions)
        elif count_star >= 50:
            return 10000  # 10 seconds
        elif count_star >= 20:
            return 30000  # 30 seconds
        else:
            return 60000  # 60 seconds

    def generate_cache_rule(self, query: QueryDigest, rule_id: int) -> str:
        """Generate ProxySQL cache rule SQL statement"""
        # Extract table pattern from query
        pattern = self._extract_query_pattern(query.digest_text)
        ttl = self.suggest_ttl(query.count_star, query.avg_time)

        return f"""-- Rule {rule_id}: Cache {query.digest_text[:60]}... (TTL: {ttl/1000:.0f}s, Score: {query.cache_score:.1f})
INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup, cache_ttl, apply)
VALUES ({rule_id}, 1, '{pattern}', 10, {ttl}, 1);"""

    def _extract_query_pattern(self, digest_text: str) -> str:
        """Extract regex pattern from digest text for cache rule matching"""
        # Remove parameter placeholders and create regex pattern
        import re

        # Replace ? with .* for flexible matching
        pattern = digest_text.replace('?', '.*')

        # Only escape regex special chars that aren't SQL keywords
        # ProxySQL uses regex directly on SQL - don't escape spaces, asterisks in SELECT *, etc.
        pattern = pattern.replace('(', r'\(').replace(')', r'\)')
        pattern = pattern.replace('[', r'\[').replace(']', r'\]')
        pattern = pattern.replace('{', r'\{').replace('}', r'\}')
        pattern = pattern.replace('+', r'\+').replace('|', r'\|')
        pattern = pattern.replace('$', r'\$')  # But allow ^ for start anchor

        # Add ^ anchor for start of query
        if not pattern.startswith('^'):
            pattern = '^' + pattern

        # Limit pattern length to first 100 chars for readability
        if len(pattern) > 100:
            # Try to find a reasonable cutoff point (after FROM clause)
            from_idx = pattern.upper().find('FROM')
            if from_idx > 0:
                pattern = pattern[:from_idx + 30] + '.*'
            else:
                pattern = pattern[:100] + '.*'

        return pattern

    def print_header(self):
        """Print MySQLTuner-style header"""
        print(f"\n >>  ProxySQL Metrics Analyzer {self.VERSION}")
        print("     * Analysis tool for ProxySQL query caching optimization")
        print(" >>  by George Liu (eva2000) at https://centminmod.com/")
        print(" >>  ProxySQL Admin Interface Analysis\n")

    def print_connection_info(self, version: str):
        """Print connection information section"""
        print("-------- Connection Info " + "-" * 64)
        print(f"✔  Connected to ProxySQL Admin Interface ({self.host}:{self.port})")
        print(f"✔  ProxySQL Version: {version}")

        # Get backend server count and status
        pool_stats = self.get_extended_connection_pool_stats()
        online_count = sum(1 for p in pool_stats if p.status == 'ONLINE')
        total_count = len(pool_stats)

        if total_count > 0:
            print(f"✔  Backend Servers: {online_count} ONLINE (Total: {total_count})")
        print()

    def print_top_queries(self, queries: List[QueryDigest], top_n: int = 20):
        """Print top SELECT queries for caching"""
        print("-------- Top SELECT Queries for Caching " + "-" * 46)
        print(f"{'Rank':<6}{'Query Pattern':<50}{'Exec':<10}{'Total(μs)':<12}{'Avg(μs)':<10}{'Score':<8}")
        print("-" * 96)

        select_queries = [q for q in queries if q.is_select and q.hostgroup != -1]
        top_queries = sorted(select_queries, key=lambda q: q.cache_score, reverse=True)[:top_n]

        for idx, query in enumerate(top_queries, 1):
            # Truncate query text for display
            query_text = query.digest_text[:48] + ".." if len(query.digest_text) > 50 else query.digest_text
            print(f"{idx:<6}{query_text:<50}{query.count_star:<10}{query.sum_time:<12}{query.avg_time:<10.1f}{query.cache_score:<8.1f}")

        print()
        return top_queries

    def print_cache_stats(self, stats: CacheStats):
        """Print query cache performance metrics"""
        print("-------- Query Cache Performance " + "-" * 56)
        print(f"Query_Cache_Memory_bytes: {stats.memory_bytes:,}")
        print(f"Query_Cache_Entries: {stats.entries}")
        print(f"Query_Cache_Hit_Rate: {stats.hit_rate:.1f}% ({stats.count_get_ok} hits / {stats.count_get} requests)")
        print(f"Query_Cache_count_SET: {stats.count_set}")
        print(f"Query_Cache_bytes_IN: {stats.bytes_in:,}")
        print(f"Query_Cache_bytes_OUT: {stats.bytes_out:,}")
        print(f"Query_Cache_Purged: {stats.purged}")
        print()

    def print_connection_pool_efficiency(self, pools: List[ConnectionPoolStats]):
        """Print connection pool efficiency analysis with derived metrics"""
        print("-------- Connection Pool Efficiency Analysis " + "-" * 42)
        print(f"{'Hostgroup':<12}{'Server':<20}{'Utilization':<13}{'Success Rate':<14}{'Queries/Conn':<14}{'Latency(ms)':<13}{'Score':<8}")
        print("-" * 94)

        for pool in pools:
            server = f"{pool.srv_host}:{pool.srv_port}"
            print(f"{pool.hostgroup:<12}{server:<20}{pool.pool_utilization:>11.1f}% {pool.connection_success_rate:>12.1f}% "
                  f"{pool.queries_per_connection:<14.1f}{pool.avg_latency_ms:<13.2f}{pool.efficiency_score:<8.1f}")

        print()

    def print_global_performance(self, stats: GlobalStats):
        """Print ProxySQL global performance metrics"""
        print("-------- ProxySQL Global Performance Metrics " + "-" * 42)
        print(f"ProxySQL_Uptime: {stats.uptime_formatted}")
        print(f"Client_Connections_connected: {stats.client_connections_connected:,}")
        print(f"Server_Connections_created: {stats.server_connections_created:,}")
        print(f"Multiplexing_Ratio: {stats.multiplexing_ratio:.1f}x ({stats.client_connections_connected:,} frontend → {stats.server_connections_created:,} backend)")
        print(f"Total_Queries: {stats.queries_total:,}")
        print(f"Slow_Queries: {stats.slow_queries:,} ({stats.slow_query_rate:.3f}%)")
        print(f"Active_Transactions: {stats.active_transactions:,}")
        print()

    def print_health_checks(self, ping_checks: List[HealthCheckStats], connect_checks: List[HealthCheckStats]):
        """Print backend health check monitoring statistics"""
        if not ping_checks and not connect_checks:
            return

        print("-------- Backend Health Checks (Last 5 Minutes) " + "-" * 40)
        print(f"{'Type':<12}{'Server':<20}{'Total Checks':<14}{'Failed':<10}{'Success Rate':<14}{'Avg Time(ms)':<15}")
        print("-" * 85)

        for check in ping_checks:
            server = f"{check.hostname}:{check.port}"
            print(f"{check.check_type.capitalize():<12}{server:<20}{check.total_checks:<14}{check.failed_checks:<10}"
                  f"{check.success_rate:>12.1f}% {check.avg_time_ms:<15.2f}")

        for check in connect_checks:
            server = f"{check.hostname}:{check.port}"
            print(f"{check.check_type.capitalize():<12}{server:<20}{check.total_checks:<14}{check.failed_checks:<10}"
                  f"{check.success_rate:>12.1f}% {check.avg_time_ms:<15.2f}")

            if check.last_error and check.failed_checks > 0:
                print(f"  └─ Last Error: {check.last_error}")

        print()

    def print_free_connections(self, summary: FreeConnectionSummary):
        """Print free connection pool analysis"""
        if summary.total_free == 0:
            return

        print("-------- Free Connection Pool Analysis " + "-" * 50)
        print(f"Total Free Connections: {summary.total_free:,}")
        print(f"Stale Connections (idle > 5min): {summary.total_stale:,} ({summary.stale_percentage:.1f}%)")
        print(f"Average Idle Time: {summary.avg_idle_ms/1000:.1f}s")
        print(f"Max Idle Time: {summary.max_idle_minutes:.1f} minutes")
        print()

        # Connections by hostgroup
        if summary.connections_by_hostgroup:
            print("Free Connections by Hostgroup:")
            for hg, count in sorted(summary.connections_by_hostgroup.items()):
                print(f"  Hostgroup {hg}: {count:,} connections")
            print()

        # Connections by user
        if summary.connections_by_user:
            print("Free Connections by User:")
            for user, count in sorted(summary.connections_by_user.items(), key=lambda x: x[1], reverse=True)[:5]:
                print(f"  {user}: {count:,} connections")
            print()

    def print_memory_metrics(self, metrics: MemoryMetrics):
        """Print ProxySQL memory usage metrics"""
        if metrics.jemalloc_allocated == 0 and metrics.jemalloc_resident == 0:
            return

        print("-------- ProxySQL Memory Usage " + "-" * 56)
        print(f"Jemalloc Allocated: {metrics.jemalloc_allocated_mb:.2f} MB")
        print(f"Jemalloc Resident (RSS): {metrics.jemalloc_resident_mb:.2f} MB")
        print(f"Memory Overhead: {metrics.memory_overhead_pct:.1f}%")
        print()

        print("Component Memory Breakdown:")
        print(f"  Query Digest Cache: {metrics.query_digest_memory_mb:.2f} MB")
        print(f"  Auth Cache: {metrics.auth_memory / (1024*1024):.2f} MB")
        print(f"  SQLite: {metrics.sqlite3_memory_bytes / (1024*1024):.2f} MB")
        print(f"  Thread Stacks: {metrics.total_stack_memory_mb:.2f} MB")
        print()

    def print_pool_recommendations(self, pools: List[ConnectionPoolStats], global_stats: GlobalStats):
        """Print connection pool tuning recommendations based on metrics"""
        recommendations = []

        for pool in pools:
            # High efficiency - positive feedback
            if pool.efficiency_score >= 85:
                recommendations.append(
                    f"✔  Hostgroup {pool.hostgroup}: Excellent connection pool efficiency ({pool.efficiency_score:.1f}/100 score)"
                )

            # Low utilization warning
            if pool.pool_utilization < 20 and pool.total_connections > 10:
                recommendations.append(
                    f"⚠  Hostgroup {pool.hostgroup}: Low utilization ({pool.pool_utilization:.1f}%) - "
                    f"Consider reducing max_connections (current pool: {pool.total_connections})"
                )

            # High error rate alert
            if pool.connection_success_rate < 95 and pool.conn_err > 0:
                recommendations.append(
                    f"✗  Hostgroup {pool.hostgroup}: High connection errors ({pool.conn_err} failures, {pool.connection_success_rate:.1f}% success) - "
                    f"Investigate backend {pool.srv_host}:{pool.srv_port} health"
                )

            # High latency warning
            if pool.avg_latency_ms > 10:
                recommendations.append(
                    f"⚠  Hostgroup {pool.hostgroup}: High backend latency ({pool.avg_latency_ms:.2f}ms) - "
                    f"Check network/backend performance for {pool.srv_host}"
                )

            # Low queries per connection (inefficient pooling)
            if pool.queries_per_connection < 10 and pool.queries > 100:
                recommendations.append(
                    f"ℹ  Hostgroup {pool.hostgroup}: Low queries/connection ({pool.queries_per_connection:.1f}) - "
                    f"Connection churning detected, verify transaction_persistent=1"
                )

        # Global multiplexing analysis
        if global_stats.multiplexing_ratio >= 10:
            recommendations.append(
                f"✔  Strong multiplexing ratio ({global_stats.multiplexing_ratio:.1f}x) reducing backend load effectively"
            )
        elif global_stats.multiplexing_ratio < 5 and global_stats.server_connections_created > 10:
            recommendations.append(
                f"⚠  Low multiplexing ratio ({global_stats.multiplexing_ratio:.1f}x) - "
                f"Enable transaction_persistent=1 for better connection pooling"
            )

        # Slow query rate
        if global_stats.slow_query_rate > 1.0:
            recommendations.append(
                f"⚠  High slow query rate ({global_stats.slow_query_rate:.2f}%) - "
                f"Review mysql-long_query_time threshold and optimize slow queries"
            )

        # Print recommendations
        if recommendations:
            print("Connection Pool Tuning Recommendations:")
            for rec in recommendations:
                print(f"  {rec}")
            print()

    def print_connection_pool_analysis(self, free_conns: FreeConnectionSummary,
                                       pool_stats: List[ConnectionPoolStats]):
        """Generate recommendations for connection pool management"""
        if free_conns.total_free == 0:
            return

        recommendations = []

        # Stale connection detection
        if free_conns.total_stale > 10:
            recommendations.append(
                f"⚠️  {free_conns.total_stale} stale connections detected (idle > 5min). "
                f"Consider reducing mysql-wait_timeout or investigating connection leaks."
            )

        # Excessive free connections
        if free_conns.total_free > 100:
            total_used = sum(p.conn_used for p in pool_stats)
            recommendations.append(
                f"ℹ️  High free connection count ({free_conns.total_free}). "
                f"Pool may be oversized. Current utilization: {total_used} used vs {free_conns.total_free} free."
            )

        # Average idle time too high
        if free_conns.avg_idle_ms > 120000:  # > 2 minutes
            recommendations.append(
                f"💡 Average idle time is {free_conns.avg_idle_ms/1000:.0f}s. "
                f"Consider tuning mysql-free_connections_pct to release idle connections faster."
            )

        if recommendations:
            print("-------- Free Connection Pool Recommendations " + "-" * 41)
            for rec in recommendations:
                print(f"{rec}")
                print()

    def print_memory_recommendations(self, metrics: MemoryMetrics):
        """Generate recommendations for memory optimization"""
        if metrics.jemalloc_allocated == 0 and metrics.jemalloc_resident == 0:
            return

        recommendations = []

        # High resident memory
        if metrics.jemalloc_resident_mb > 1024:  # > 1GB
            recommendations.append(
                f"⚠️  High memory usage detected: {metrics.jemalloc_resident_mb:.0f} MB resident. "
                f"Monitor for memory leaks and consider capacity planning."
            )

        # Query digest memory pressure
        if metrics.query_digest_memory_mb > 100:
            recommendations.append(
                f"💡 Query digest using {metrics.query_digest_memory_mb:.0f} MB. "
                f"Consider reducing mysql-query_digests_max_query_length or mysql-query_digests_max_digest_length."
            )

        # High memory overhead
        if metrics.memory_overhead_pct > 50:
            recommendations.append(
                f"⚠️  Memory overhead is {metrics.memory_overhead_pct:.1f}% "
                f"(resident: {metrics.jemalloc_resident_mb:.0f} MB, allocated: {metrics.jemalloc_allocated_mb:.0f} MB). "
                f"May indicate fragmentation or caching inefficiency."
            )

        # SQLite memory high
        sqlite_mb = metrics.sqlite3_memory_bytes / (1024*1024)
        if sqlite_mb > 50:
            recommendations.append(
                f"ℹ️  SQLite using {sqlite_mb:.0f} MB. This is normal for large configurations "
                f"but consider periodic VACUUM if admin interface feels sluggish."
            )

        if recommendations:
            print("-------- Memory Optimization Recommendations " + "-" * 44)
            for rec in recommendations:
                print(f"{rec}")
                print()

    def print_command_counters(self, counters: List[Tuple[str, int, int]]):
        """Print command counter statistics"""
        print("-------- Command Counters (Top 10) " + "-" * 53)
        print(f"{'Command':<20}{'Total Count':<15}{'Total Time (μs)':<20}")
        print("-" * 55)

        for command, count, time_us in counters:
            print(f"{command:<20}{count:<15,}{time_us:<20,}")

        print()

    def print_cache_config(self, config: Dict[str, str]):
        """Print cache configuration variables"""
        print("-------- Cache Configuration " + "-" * 60)

        mysql_cache_vars = {k: v for k, v in config.items() if k.startswith('mysql-')}

        for var, value in sorted(mysql_cache_vars.items()):
            print(f"{var}: {value}")

        print()

    def print_monitor_config(self, config: Dict[str, str]):
        """Print monitor configuration variables"""
        print("-------- Monitor Configuration " + "-" * 58)

        for var, value in sorted(config.items()):
            print(f"{var}: {value}")

        print()

    def print_existing_rules(self, rules: List[Tuple[int, str, int]]):
        """Print existing cache rules"""
        if not rules:
            print("ℹ  No existing cache rules configured")
            print()
            return

        print("-------- Existing Cache Rules " + "-" * 59)
        print(f"{'Rule ID':<10}{'Match Pattern':<60}{'TTL (ms)':<12}")
        print("-" * 82)

        for rule_id, pattern, ttl in rules:
            pattern_display = pattern[:58] + ".." if len(pattern) > 60 else pattern
            print(f"{rule_id:<10}{pattern_display:<60}{ttl:<12}")

        print()

    def print_recommendations(self, top_queries: List[QueryDigest], existing_rules: List[Tuple]):
        """Print cache rule recommendations"""
        print("-------- Recommendations " + "-" * 64)
        print("ProxySQL Query Cache Rules (Top 20 SELECT Query Candidates):\n")

        # Start rule IDs after existing ones
        existing_ids = {rule[0] for rule in existing_rules}
        next_rule_id = max(existing_ids, default=100) + 1

        for query in top_queries:
            rule_sql = self.generate_cache_rule(query, next_rule_id)
            print(rule_sql)
            print()
            next_rule_id += 1

        print("\n-- Apply all rules to ProxySQL runtime:")
        print("LOAD MYSQL QUERY RULES TO RUNTIME;")
        print("SAVE MYSQL QUERY RULES TO DISK;\n")

        # Additional recommendations
        print("General Recommendations:")
        print("  * Monitor cache hit rate - aim for >70% for cached query patterns")
        print("  * Adjust TTL values based on data update frequency")
        print("  * ProxySQL query cache has NO automatic invalidation")
        print("  * Cache is best for read-heavy workloads with tolerable staleness")
        print("  * Review stats_mysql_query_digest regularly for new cache candidates")
        print()

    def run_analysis(self, top_n: int = 20):
        """Run complete ProxySQL metrics analysis"""
        self.print_header()

        if not self.connect():
            print("✗  Failed to connect to ProxySQL admin interface")
            sys.exit(1)

        try:
            # Connection info
            version = self.get_proxysql_version()
            self.print_connection_info(version)

            # Query digest analysis
            all_queries = self.get_query_digest(limit=200)
            top_queries = self.print_top_queries(all_queries, top_n=top_n)

            # Cache statistics
            cache_stats = self.get_cache_stats()
            self.print_cache_stats(cache_stats)

            # Extended connection pool efficiency
            pool_stats = self.get_extended_connection_pool_stats()
            self.print_connection_pool_efficiency(pool_stats)

            # Global performance metrics
            global_stats = self.get_global_stats()
            self.print_global_performance(global_stats)

            # Backend health checks
            ping_checks, connect_checks = self.get_health_checks()
            self.print_health_checks(ping_checks, connect_checks)

            # Free connection analysis
            free_conns = self.get_free_connections()
            self.print_free_connections(free_conns)

            # Memory metrics
            memory_metrics = self.get_memory_metrics()
            self.print_memory_metrics(memory_metrics)

            # Command counters
            commands = self.get_command_counters()
            self.print_command_counters(commands)

            # Cache configuration
            cache_config = self.get_cache_config()
            self.print_cache_config(cache_config)

            # Monitor configuration
            monitor_config = self.get_monitor_config()
            self.print_monitor_config(monitor_config)

            # Existing rules
            existing_rules = self.get_existing_cache_rules()
            self.print_existing_rules(existing_rules)

            # Cache rule recommendations
            self.print_recommendations(top_queries, existing_rules)

            # Connection pool recommendations
            self.print_pool_recommendations(pool_stats, global_stats)

            # Free connection recommendations
            self.print_connection_pool_analysis(free_conns, pool_stats)

            # Memory recommendations
            self.print_memory_recommendations(memory_metrics)

        finally:
            self.close()


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description="ProxySQL Metrics Analyzer - MySQLTuner equivalent for ProxySQL",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  uv run proxysql_report.py --host 127.0.0.1 --port 6032 --user admin --password admin
  uv run proxysql_report.py --host 127.0.0.1 --port 6032 --user admin --password admin --top 30

by George Liu (eva2000) at https://centminmod.com/
        """
    )

    parser.add_argument('--host', default='127.0.0.1',
                       help='ProxySQL admin interface host (default: 127.0.0.1)')
    parser.add_argument('--port', type=int, default=6032,
                       help='ProxySQL admin interface port (default: 6032)')
    parser.add_argument('--user', default='admin',
                       help='ProxySQL admin user (default: admin)')
    parser.add_argument('--password', default='admin',
                       help='ProxySQL admin password (default: admin)')
    parser.add_argument('--top', type=int, default=20,
                       help='Number of top queries to analyze (default: 20)')
    parser.add_argument('--version', action='version',
                       version=f'ProxySQL Metrics Analyzer {ProxySQLAnalyzer.VERSION}')

    args = parser.parse_args()

    analyzer = ProxySQLAnalyzer(
        host=args.host,
        port=args.port,
        user=args.user,
        password=args.password
    )

    analyzer.run_analysis(top_n=args.top)


if __name__ == '__main__':
    main()
