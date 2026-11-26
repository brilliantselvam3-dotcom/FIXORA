# frozen_string_literal: true

require 'openssl'
require 'securerandom'
require 'time'

class AuthError < StandardError
  attr_reader :status

  def initialize(message, status = 401)
    super(message)
    @status = status
  end
end

module Auth
  SESSION_TTL_SECONDS = 24 * 60 * 60
  PBKDF2_ITERATIONS = 10_000

  module_function

  def hash_password(password)
    salt = SecureRandom.hex(16)
    digest = OpenSSL::PKCS5.pbkdf2_hmac(
      password.to_s,
      salt,
      PBKDF2_ITERATIONS,
      32,
      OpenSSL::Digest::SHA256.new
    ).unpack1('H*')
    "pbkdf2_sha256$#{PBKDF2_ITERATIONS}$#{salt}$#{digest}"
  end

  def verify_password(password, stored_hash)
    parts = stored_hash.to_s.split('$')
    return false unless parts.length == 4 && parts[0] == 'pbkdf2_sha256'

    iterations = parts[1].to_i
    salt = parts[2]
    expected_hex = parts[3]
    computed_hex = OpenSSL::PKCS5.pbkdf2_hmac(
      password.to_s,
      salt,
      iterations,
      32,
      OpenSSL::Digest::SHA256.new
    ).unpack1('H*')

    secure_compare(expected_hex, computed_hex)
  end

  def secure_compare(a, b)
    return false unless a.bytesize == b.bytesize

    l = a.unpack('C*')
    r = b.unpack('C*')
    res = 0
    l.zip(r) { |x, y| res |= x ^ y }
    res.zero?
  end

  def login(db, email, password)
    normalized_email = email.to_s.strip.downcase
    raise AuthError.new('Email and password are required.', 400) if normalized_email.empty? || password.to_s.empty?

    user = db.query_one(
      'SELECT user_id, name, email, password_hash, role, department, active FROM users WHERE LOWER(email) = ?',
      [normalized_email]
    )
    raise AuthError.new('Invalid email or password.', 401) unless user
    raise AuthError.new('Account is inactive.', 403) unless user['active'].to_i == 1
    raise AuthError.new('Invalid email or password.', 401) unless verify_password(password, user['password_hash'])

    token = SecureRandom.hex(32)
    now = Time.now.utc
    expires = now + SESSION_TTL_SECONDS
    db.execute(
      'INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
      [token, user['user_id'], now.iso8601, expires.iso8601]
    )

    {
      token: token,
      expires_at: expires.iso8601,
      user: public_user(user)
    }
  end

  def authenticate!(db, req)
    header = req['Authorization'] || req['authorization']
    token = nil
    if header && header =~ /\ABearer\s+(.+)\z/i
      token = Regexp.last_match(1).strip
    elsif req.query && req.query['token']
      token = req.query['token'].to_s.strip
    end

    raise AuthError.new('Authentication required.', 401) if token.nil? || token.empty?

    row = db.query_one(
      <<~SQL,
        SELECT s.token, s.expires_at, u.user_id, u.name, u.email, u.role, u.department, u.active
        FROM sessions s
        JOIN users u ON u.user_id = s.user_id
        WHERE s.token = ?
      SQL
      [token]
    )
    raise AuthError.new('Invalid or expired session token.', 401) unless row
    raise AuthError.new('Account is inactive.', 403) unless row['active'].to_i == 1

    if Time.parse(row['expires_at']) < Time.now.utc
      db.execute('DELETE FROM sessions WHERE token = ?', [token])
      raise AuthError.new('Session expired. Please sign in again.', 401)
    end

    public_user(row).merge('token' => token)
  end

  def logout(db, token)
    return if token.nil? || token.empty?

    db.execute('DELETE FROM sessions WHERE token = ?', [token])
  end

  def require_role!(user, *allowed_roles)
    roles = allowed_roles.flatten.map(&:to_s)
    return if roles.include?(user['role'])

    raise AuthError.new("Forbidden: #{user['role']} role cannot perform this action.", 403)
  end

  def list_users(db, current_user, role_filter: nil)
    require_role!(current_user, 'admin')

    sql = <<~SQL
      SELECT
        u.user_id, u.name, u.email, u.role, u.department, u.active, u.created_at,
        COALESCE(SUM(CASE WHEN t.status = 'Assigned' THEN 1 ELSE 0 END), 0) AS assigned_count,
        COALESCE(SUM(CASE WHEN t.status = 'In Progress' THEN 1 ELSE 0 END), 0) AS in_progress_count,
        COALESCE(SUM(CASE WHEN t.status = 'Resolved' THEN 1 ELSE 0 END), 0) AS resolved_count
      FROM users u
      LEFT JOIN tickets t ON t.technician_id = u.user_id
    SQL

    params = []
    if role_filter && !role_filter.strip.empty?
      sql += ' WHERE u.role = ?'
      params << role_filter.strip.downcase
    end
    sql += ' GROUP BY u.user_id ORDER BY u.role, u.name'

    db.query(sql, params)
  end

  def create_user(db, current_user, payload)
    require_role!(current_user, 'admin')

    name = payload['name'].to_s.strip
    email = payload['email'].to_s.strip.downcase
    password = payload['password'].to_s
    role = payload['role'].to_s.strip.downcase
    department = payload['department'].to_s.strip

    raise AuthError.new('Name, email, password, role, and department are required.', 400) if [name, email, password, role, department].any?(&:empty?)
    raise AuthError.new("Invalid role '#{role}'. Must be reporter, technician, or admin.", 400) unless %w[reporter technician admin].include?(role)
    raise AuthError.new('Password must be at least 6 characters.', 400) if password.length < 6

    existing = db.query_one('SELECT user_id FROM users WHERE LOWER(email) = ?', [email])
    raise AuthError.new("A user with email '#{email}' already exists.", 409) if existing

    prefix = case role
             when 'reporter' then 'USR-REP'
             when 'technician' then 'USR-TECH'
             else 'USR-ADM'
             end
    user_id = "#{prefix}-#{SecureRandom.hex(3).upcase}"
    now = Time.now.utc.iso8601

    db.execute(
      'INSERT INTO users (user_id, name, email, password_hash, role, department, active, created_at) VALUES (?, ?, ?, ?, ?, ?, 1, ?)',
      [user_id, name, email, hash_password(password), role, department, now]
    )

    {
      'user_id' => user_id,
      'name' => name,
      'email' => email,
      'role' => role,
      'department' => department,
      'active' => 1,
      'created_at' => now
    }
  end

  def public_user(row)
    {
      'user_id' => row['user_id'],
      'name' => row['name'],
      'email' => row['email'],
      'role' => row['role'],
      'department' => row['department']
    }
  end
end
