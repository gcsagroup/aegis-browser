# frozen_string_literal: true

require 'fiddle/import'
require 'json'

module DarwinACL
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)

  ACL_TYPE_EXTENDED = 0x0100
  ATTR_BIT_MAP_COUNT = 5
  ATTR_VOL_INFO = 0x80000000
  ATTR_VOL_MOUNTFLAGS = 0x00004000
  MNT_IGNORE_OWNERSHIP = 0x00200000

  extern 'int fgetattrlist(int, void *, void *, size_t, unsigned long)'
  extern 'void *acl_get_fd_np(int, int)'
  extern 'void *acl_to_text(void *, void *)'
  extern 'int acl_free(void *)'

  def self.ignores_ownership?(fd)
    # Request the volume mount flags from the same directory descriptor.
    attributes = [ATTR_BIT_MAP_COUNT, 0, 0, ATTR_VOL_INFO | ATTR_VOL_MOUNTFLAGS, 0, 0, 0].pack('S2L5')
    result = "\0" * 8
    if fgetattrlist(fd, attributes, result, result.bytesize, 0) != 0
      raise SystemCallError.new('fgetattrlist', Fiddle.last_error)
    end

    size, flags = result.unpack('L2')
    raise 'Invalid mount flag data' unless size == result.bytesize

    (flags & MNT_IGNORE_OWNERSHIP) != 0
  end

  def self.read(fd)
    acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
    if acl.null?
      error = Fiddle.last_error
      # The descriptor exists. ENOENT indicates there is no extended ACL.
      return '' if error == Errno::ENOENT::Errno

      raise SystemCallError.new('acl_get_fd_np', error)
    end

    begin
      text = acl_to_text(acl, nil)
      raise SystemCallError.new('acl_to_text', Fiddle.last_error) if text.null?

      begin
        text.to_s
      ensure
        acl_free(text)
      end
    ensure
      acl_free(acl)
    end
  end
end

File.open(ARGV.fetch(0), File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |directory|
  info = directory.stat
  raise ArgumentError, 'Expected an output directory' unless info.directory?

  ignores_ownership = DarwinACL.ignores_ownership?(directory.fileno)
  acl = ignores_ownership ? '' : DarwinACL.read(directory.fileno)
  STDOUT.write(JSON.generate(uid: info.uid, mode: info.mode, acl: acl, ignoresOwnership: ignores_ownership))
end
