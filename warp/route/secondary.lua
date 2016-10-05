local dns, rrparser = require('dns'), require('dns.rrparser')
local now = require('dns.nbio').now
local ffi = require('ffi')

-- Pooled objects
local cached_txn, cached_rr = nil, ffi.gc(dns.rrset(), dns.rrset.init)

local function log_event(msg, ...)
	local log = require('warp.init').log
	log(nil, 'info', msg, ...)
end

local M = {}

-- Add RR to packet and send it out if it's full
local function add_rr(req, writer, rr)
	if not req.answer:put(rr, req.xfer) then
		assert(writer(req, req.answer, req.addr))
		req.msg:toanswer(req.answer)
		req.answer:aa(true)
		req.answer:put(rr, req.xfer) -- Promise not to access RR afterwards
		return 1
	end
	return 0
end

local function positive(self, req, writer, rr, txn)
	rr = self.store:get(txn, req.qname, req.qtype, rr)
	add_rr(req, writer, rr)
	return 
end

local function negative(self, req, writer, rr, txn)
	table.insert(req.authority, req.soa)
end

local function answer(self, req, writer, rr, txn)
	-- Find name encloser in given zone
	local encloser, cut = self.store:encloser(txn, req.qname, req.soa, rr)
	if cut then -- Name is below a zone cut
		table.insert(req.authority, cut:copy())
		-- TODO: fill glue records
		return
	end
	-- Zone is authoritative for this name
	req.answer:aa(true)
	-- Encloser is equal to QNAME
	if req.qname:equals(encloser) then
		return positive(self, req, writer, rr, txn)
	end
	-- No match for given name
	return negative(self, req, writer, rr)
end

-- Answer query from zonefile
local function serve(self, req, writer)
	local txn = cached_txn
	if txn then
		txn:renew()
	else
		txn = self.store:txn(true)
		cached_txn = txn
	end
	-- Find zone apex for given name
	local rr = cached_rr
	local soa = self.store:zone(txn, req.qname, rr)
	if not soa then
		req:vlog('%s: refused (no zone found)', req.qname)
		req.answer:rcode(dns.rcode.REFUSED)
		txn:reset()
		return -- No file to process, bail
	end
	-- Set zone authority and build answer
	req.soa = soa:copy()
	answer(self, req, writer, rr, txn)
	txn:reset()
	return
end

local function update(store, keys, txn, rr)
	local ok, key = store:set(txn, rr)
	keys[key] = nil
	rr:clear()
	return 1
end

local function sync_file(self, zone, path)
	-- Open parser and start new txn
	local parser = assert(rrparser.new())
	assert(parser:open(path))
	local txn = self.store:txn()
	-- Get current version of given zone
	local current, serial, current_keys
	do
		local rr = self.store:get(txn, zone, dns.type.SOA)
		if rr then
			current = dns.rdata.soa_serial(rr:rdata(0))
		end
	end
	-- Start parsing the source file
	collectgarbage()
	local updated, deleted, start = 0, 0, now()
	local rr = dns.rrset(nil, 0)
	while parser:parse() do
		-- Compare SOA serial to current
		if parser.r_type == dns.type.SOA then
			serial = dns.rdata.soa_serial(parser.r_data)
			-- SOA serial unchanged, abort
			if current and serial == current then
				log_event('zone: %s, status: unchanged (serial: %u)', zone, current)
				parser:reset()
				txn:abort()
				return
			else
				-- Get all keys present in current version of a zone
				log_event('zone: %s, status: syncing (serial: %u -> %u)', zone, current or 0, serial)
				current_keys = self.store:scan(txn, zone)
			end
		end
		-- Merge records into RR sets
		if rr:empty() then
			rr:init(parser.r_owner, parser.r_type)
		elseif rr:type() ~= parser.r_type or not rr:owner():equals(parser.r_owner, parser.r_owner_length) then
			-- Store complete RR set and start new
			updated = updated + update(self.store, current_keys, txn, rr)
			rr:init(parser.r_owner, parser.r_type)
		end
		rr:add(parser.r_data, parser.r_ttl, parser.r_data_length)
	end
	-- Insert last RR set
	if not rr:empty() then
		updated = updated + update(self.store, current_keys, txn, rr)
	end
	parser:reset()
	collectgarbage()
	-- Delete keys that do not exist in new version
	if current_keys then
		for k, _ in pairs(current_keys) do
			self.store:del(txn, k)
			deleted = deleted + 1
		end
	end
	txn:commit()
	log_event('zone: %s, status: done (updated: %u, removed: %u, time: %.03fs)',
		zone, updated, deleted, now() - start)
end

-- Synchronise with backing store
local function sync(self)
	if not self.source then return end
	-- File source backend
	for _,v in ipairs(dns.utils.ls(self.source)) do
		if v:find('.zone$') then
			local path = self.source .. '/' .. v
			local zone = dns.dname.parse(v:match('(%S+).zone$'))
			sync_file(self, zone, path)
		end
	end
end

-- Module initialiser
function M.init(conf)
	conf = conf or {}
	conf.path = conf.path or '.'
	conf.store = conf.store or 'lmdb'
	-- Check if store is available and open it
	local ok, store = pcall(require, 'warp.store.' .. conf.store)
	assert(ok, string.format('store "%s" is not available: %s', conf.store, store))
	conf.store = assert(store.open(conf))
	-- Synchronise
	sync(conf)
	-- Route API
	conf.serve = serve
	return conf
end

return M