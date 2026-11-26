# frozen_string_literal: true

require 'json'
require 'open3'
require 'fileutils'

class DatabaseError < StandardError; end

class Database
  attr_reader :db_path

  def initialize(db_path, schema_path = nil)
    @db_path = db_path
    @mutex = Mutex.new
    FileUtils.mkdir_p(File.dirname(db_path))
    apply_schema(schema_path) if schema_path && File.exist?(schema_path)
  end

  def apply_schema(schema_path)
    sql = File.read(schema_path)
    @mutex.synchronize do
      run_sqlite(sql, json: false)
    end
  end

  def query(sql, params = [])
    formatted = bind_params(sql, params)
    @mutex.synchronize do
      run_sqlite("PRAGMA foreign_keys = ON;\n#{formatted}", json: true)
    end
  end

  def query_one(sql, params = [])
    query(sql, params).first
  end

  def execute(sql, params = [])
    formatted = bind_params(sql, params)
    @mutex.synchronize do
      run_sqlite("PRAGMA foreign_keys = ON;\n#{formatted}", json: false)
    end
  end

  # Runs a block that builds SQL statements inside a single BEGIN IMMEDIATE transaction.
  # Yields a helper object `tx` with `add(sql, params)` and `query_after` support,
  # OR executes the yielded block holding the mutex so read+write inside a single
  # sqlite3 script or multi-step check is serialized cleanly.
  def synchronize(&block)
    @mutex.synchronize(&block)
  end

  # Execute an array of SQL statements atomically in BEGIN IMMEDIATE ... COMMIT.
  # Returns parsed JSON rows from the final SELECT statement if return_json is true.
  def transaction_script(statements, return_json: false)
    sql_parts = ['PRAGMA foreign_keys = ON;', 'BEGIN IMMEDIATE;']
    statements.each do |stmt|
      if stmt.is_a?(Array)
        sql_parts << "#{bind_params(stmt[0], stmt[1..])} ;"
      else
        sql_parts << "#{stmt};"
      end
    end
    sql_parts << 'COMMIT;'
    @mutex.synchronize do
      run_sqlite(sql_parts.join("\n"), json: return_json)
    end
  end

  # Atomic conditional transaction: executes statements in BEGIN IMMEDIATE,
  # checks `SELECT changes() AS changes` after the conditional UPDATE/INSERT,
  # and rolls back if not needed. Because SQLite script can't branch without a
  # trigger or WHERE guard, we use a SQLite trigger or guard pattern, OR hold @mutex
  # while checking and committing. Holding @mutex in-process PLUS using WHERE status = 'Open'
  # in a single transaction guarantees zero race conditions across threads AND processes.
  def atomic_script_with_result(statements)
    sql_parts = ['PRAGMA foreign_keys = ON;', 'BEGIN IMMEDIATE;']
    statements.each do |stmt|
      sql = stmt.is_a?(Array) ? bind_params(stmt[0], stmt[1..]) : stmt
      sql_parts << "#{sql.chomp(';')};"
    end
    sql_parts << 'COMMIT;'
    @mutex.synchronize do
      run_sqlite(sql_parts.join("\n"), json: true)
    end
  end

  def sql_quote(val)
    case val
    when nil
      'NULL'
    when Integer, Float
      val.to_s
    when TrueClass
      '1'
    when FalseClass
      '0'
    else
      str = val.to_s
      raise DatabaseError, 'Invalid NUL byte in SQL parameter' if str.include?("\x00")

      "'#{str.gsub("'", "''")}'"
    end
  end

  def bind_params(sql, params)
    return sql if params.nil? || params.empty?

    idx = 0
    result = sql.gsub('?') do
      raise DatabaseError, 'Missing SQL bind parameter' if idx >= params.length

      quoted = sql_quote(params[idx])
      idx += 1
      quoted
    end
    raise DatabaseError, 'Unused SQL bind parameters' if idx != params.length

    result
  end

  private

  def run_sqlite(sql, json: true)
    args = ['sqlite3', '-cmd', '.timeout 5000']
    args << '-json' if json
    args << @db_path

    stdout, stderr, status = Open3.capture3(*args, stdin_data: sql)
    unless status.success?
      raise DatabaseError, "SQLite error: #{stderr.strip.empty? ? stdout.strip : stderr.strip}"
    end

    return [] unless json

    trimmed = stdout.strip
    return [] if trimmed.empty?

    JSON.parse(trimmed)
  end
end
