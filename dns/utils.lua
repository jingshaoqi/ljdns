local utils = {}
local ffi = require('ffi')
local bit = require('bit')

-- Compatibility with older LJ that doesn't have table.clear()
if not table.clear then
	table.clear = function (t)  -- luacheck: ignore
		for i, _ in ipairs(t) do
			t[i] = nil
		end
	end
end

-- Return DLL extension
function utils.libname(lib, ver)
	assert(jit)
	local fmt = {
		Windows = '%s%s.dll',
		Linux = '%s.so%s', BSD = '%s.so%s', POSIX = '%s.so%s', Other = '%s.so%s',
		OSX = '%s%s.dylib'
	}
	return string.format(fmt[jit.os], lib, ver and ('.'..ver) or '')
end

-- Return versioned C library
function utils.clib(soname, versions)
	for _, v in pairs(versions) do
		local ok, lib = pcall(ffi.load, utils.libname(soname, tostring(v)))
		if ok then return lib end
	end
end

-- Hexdump from http://lua-users.org/wiki/HexDump
function utils.hexdump(buf)
	if buf == nil then return nil end
	for byte=1, #buf, 16 do
		local chunk = buf:sub(byte, byte+15)
		io.write(string.format('%08X  ',byte-1))
		chunk:gsub('.', function (c) io.write(string.format('%02X ',string.byte(c))) end)
		io.write(string.rep(' ',3*(16-#chunk)))
		io.write(' ',chunk:gsub('%c','.'),"\n") 
	end
end

-- FFI + C code
local knot = utils.clib('libknot', {2,3})
local cutil = ffi.load(package.searchpath('kdns_clib', package.cpath))
ffi.cdef[[
/* libc */
char *strdup(const char *s);
void *calloc(size_t nmemb, size_t size);
void free(void *ptr);
int memcmp(const void *a, const void *b, size_t len);
/* helper library */
unsigned mtime(const char *path);
int dnamecmp(const uint8_t *lhs, const uint8_t *rhs);
typedef uint8_t knot_rdata_t;
uint16_t knot_rdata_rdlen(const knot_rdata_t *rr);
uint8_t *knot_rdata_data(const knot_rdata_t *rr);
size_t knot_rdata_array_size(uint16_t size);
]]

-- Byte order conversions
local rshift,band = bit.rshift,bit.band
local function n32(x) return x end
local n16 = n32
if ffi.abi('le') then
	n32 = bit.bswap
	function n16(x) return rshift(n32(x), 16) end
end
utils.n32 = n32
utils.n16 = n16

-- Compute RDATA set length
local function rdsetlen(rr)
	local p, len = rr.raw_data, 0
	for _ = 1,rr.rdcount do
		local rdlen = knot.knot_rdata_array_size(knot.knot_rdata_rdlen(p + len))
		len = len + rdlen
	end
	return len
end

-- Get RDATA set member
local function rdsetget(rr, n)
	assert(n < rr.rdcount)
	local p = rr.raw_data
	for _ = 1,n do
		local rdlen = knot.knot_rdata_array_size(knot.knot_rdata_rdlen(p))
		p = p + rdlen
	end
	return p
end

local function rdataiter(rr, it)
	it[1] = it[1] + 1
	if it[1] < rr.rdcount then
		local rdata = it[2]
		local rdlen = knot.knot_rdata_array_size(knot.knot_rdata_rdlen(rdata))
		it[2] = it[2] + rdlen
		return it, rdata
	end
end

-- Domain name wire length
local function dnamelenraw(dname)
	local p, i = dname, 0
	assert(p ~= nil)
	while p[i] ~= 0 do
		i = i + p[i] + 1
	end
	return i + 1 -- Add label count
end
local function dnamelen(dname)
	return dnamelenraw(dname.bytes)
end

-- Canonically compare domain wire name / keys
local function dnamecmp(lhs, rhs)
	return cutil.dnamecmp(lhs.bytes, rhs.bytes)
end

-- Wire writer
local function wire_tell(w)
	return w.p + w.len
end
local function wire_seek(w, len)
	assert(w.len + len <= w.maxlen)
	w.len = w.len + len
end
local function wire_write(w, val, len, pt)
	assert(w.len + len <= w.maxlen)
	if pt then
		local p = ffi.cast(pt, w.p + w.len)
		p[0] = val
	else
		ffi.copy(w.p + w.len, val, len)
	end
	w.len = w.len + len
end
local function write_u8(w, val) return wire_write(w, val, 1, ffi.typeof('uint8_t *')) end
local function write_u16(w, val) return wire_write(w, n16(val), 2, ffi.typeof('uint16_t *')) end
local function write_u32(w, val) return wire_write(w, n32(val), 4, ffi.typeof('uint32_t *')) end
local function write_bytes(w, val, len) return wire_write(w, val, len or #val, nil) end
local function wire_writer(p, maxlen)
	return {p=ffi.cast('char *', p), len=0, maxlen=maxlen, u8=write_u8, u16=write_u16, u32=write_u32, bytes=write_bytes, tell=wire_tell, seek=wire_seek}
end
utils.wire_writer=wire_writer
-- Wire reader
local function wire_read(w, len, pt)
	assert(w.len + len <= w.maxlen)
	local ret
	if pt then
		local p = ffi.cast(pt, w.p + w.len)
		ret = p[0]
	else
		ret = ffi.string(w.p + w.len, len)
	end
	w.len = w.len + len
	return ret
end
local function read_u8(w)  return wire_read(w, 1, ffi.typeof('uint8_t *')) end
local function read_u16(w) return n16(wire_read(w, 2, ffi.typeof('uint16_t *'))) end
local function read_u32(w) return n16(wire_read(w, 4, ffi.typeof('uint32_t *'))) end
local function read_bytes(w, len) return wire_read(w, len) end
local function wire_reader(p, maxlen)
	return {p=ffi.cast('char *', p), len=0, maxlen=maxlen, u8=read_u8, u16=read_u16, u32=read_u32, bytes=read_bytes, tell=wire_tell, seek=wire_seek}
end
utils.wire_reader=wire_reader

-- Export low level accessors
utils.rdlen = function (rdata)
	return knot.knot_rdata_rdlen(rdata)
end
utils.rddata = function (rdata)
	return knot.knot_rdata_data(rdata)
end
utils.rdsetlen = rdsetlen
utils.rdsetget = rdsetget
utils.rdataiter = rdataiter
utils.dnamelen = dnamelen
utils.dnamelenraw = dnamelenraw
utils.dnamecmp = dnamecmp
utils.dnamecmpraw = cutil.dnamecmp
utils.mtime = cutil.mtime

-- Reverse table
function utils.reverse(t)
	local len = #t
	for i=1, math.floor(len / 2) do
		t[i], t[len - i + 1] = t[len - i + 1], t[i]
	end
end

-- Sort FFI array (0-indexed) using bottom-up heapsort based on GSL-shell [1]
-- Selection-based sorts work better for this workload, as swaps are more expensive
-- [1]: https://github.com/franko/gsl-shell
function utils.sort(array, size)
	local elmsize = ffi.sizeof(array[0])
	local buf = ffi.new('char [?]', elmsize)
	local tmpval = ffi.cast(ffi.typeof(array[0]), buf)
	local lshift = bit.lshift

	local function sift(hole, len)
		local top, j = hole, hole
		-- Trace a path of maximum children (leaf search)
		while lshift(j + 1, 1) < len do
			j = lshift(j + 1, 1)
			if array[j]:lt(array[j - 1]) then j = j - 1 end
			ffi.copy(array + hole, array + j, elmsize)
			hole = j
		end
		if j == rshift(len - 2, 1) and band(len, 1) == 0 then
			j = lshift(j + 1, 1)
			ffi.copy(array + hole, array + (j - 1), elmsize)
			hole = j - 1
		end
		-- Sift the original element one level up (Floyd's version)
		j = rshift(hole - 1, 1)
		while top < hole and array[j]:lt(tmpval) do
			ffi.copy(array + hole, array + j, elmsize)
			hole = j
			j = rshift(j - 1, 1)
		end
		ffi.copy(array + hole, tmpval, elmsize)
	end

	-- Heapify and sort by sifting heap top
	for i = rshift(size - 2, 1), 0, -1 do
		ffi.copy(tmpval, array + i, elmsize)
		sift(i, size, nil)
	end
	-- Sort heap
	for i = size - 1, 1, -1 do
		ffi.copy(tmpval, array + i, elmsize)
		ffi.copy(array + i, array, elmsize)
		sift(0, i, nil)
	end
end

local function bsearch(array, len, owner, steps)
	-- Number of steps is specialized, this allows unrolling
	if not steps then steps = math.log(len, 2) end
	local low = 0
	for _ = 1, steps do
		len = rshift(len, 1)
		local r1 = dnamecmp(array[low + len]:owner(), owner)
		if     r1  < 0 then low = low + len + 1
		elseif r1 == 0 then return array[low + len]
		end
	end
	return array[low]
end

-- Binary search closure specialized for given array size
local function bsearcher(array, len)
	-- Number of steps can be precomputed
	local steps = math.log(len, 2)
	return function (owner)
		return bsearch(array, len, owner, steps)
	end
	-- Generate force unrolled binary search for this table length
	-- local code = [[
	-- return function (array, m1, key, dnamecmp)
	-- local low = 0
	-- ]]
	-- local m1 = len
	-- for i = 1, steps do
	-- 	m1 = m1 / 2
	-- 	code = code .. string.format([[
	-- 	if dnamecmp(array[low + %d]:owner(), key) <= 0 then
	-- 		low = low + %d
	-- 	end
	-- 	]], m1, m1)
		
	-- end
	-- code = code .. 'return array[low] end'
	-- -- Compile and wrap in closure with current upvalues
	-- code = loadstring(code)()
	-- return function (owner)
	-- 	return code(array, len, owner, dnamecmp)
	-- end
end
utils.bsearch = bsearch
utils.bsearcher = bsearcher

-- Grow generic buffer
function utils.buffer_grow(arr)
	local nlen = arr.cap
	nlen = nlen < 64 and nlen + 4 or nlen * 2
	local narr = ffi.C.realloc(arr.at, nlen * ffi.sizeof(arr.at[0]))
	if narr == nil then return false end
	arr.at = narr
	arr.cap = nlen
	return true
end

-- Search key representing owner/type pair
-- format: { u8 name [1-255], u16 type }
local function searchkey(owner, type, buf)
	local nlen = dnamelen(owner)
	if not buf then buf = ffi.new('char [?]', nlen + 3) end
	ffi.copy(buf, owner.bytes, nlen + 1)
	buf[nlen + 1] = bit.rshift(bit.band(type, 0xff00), 8)
	buf[nlen + 2] = bit.band(type, 0x00ff)
	return buf, nlen + 3
end
utils.searchkey = searchkey

-- Export basic OS operations
local _, S = pcall(require, 'syscall')
if S then
	utils.chdir = S.chdir
	utils.mkdir = S.mkdir
	local ip4, ip6 = S.t.sockaddr_in(), S.t.sockaddr_in6()
	utils.inaddr = function (addr, port)
		local n = #addr
		port = port or 0
		if n == 4 then
			ip4.port = port
			ffi.copy(ip4.addr, addr, n)
			return ip4
		elseif n == 16 then
			ip6.port = port
			ffi.copy(ip6.sin6_addr, addr, n)
			return ip6
		end
	end
end

return utils
