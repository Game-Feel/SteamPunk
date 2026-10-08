// Forge 1.20.1 and KubeJS 2001.6.5.
// Version 4 resolves the actual standing height of ordinary snow layers.
// The filename stays the same so earlier versions are replaced, not duplicated.
var fenixFlatConfig = { targets: { 'minecraft:zombie': 31, 'minecraft:skeleton': 31, 'minecraft:creeper': 31, 'minecraft:spider': 10, 'minecraft:slime': 6 }, countRadius: 128, surfaceBand: 16, minDistance: 32, maxDistance: 72, attempts: 12, globalSafetyPerPlayer: 240 }
var fenixFlatState = { version: 4, status: 'waiting', spawned: 0, attempts: 0, errors: 0, spawnedByType: {}, lastChecks: {} }
var fenixFlatTicks = 0
var fenixFlatApi = null
var fenixFlatStopped = false
var fenixFlatRandom = function () { return Math.random() }

function fenixFlatCall(object, mapped, srg, args) {
  var aliases = { m_6907_: 'getPlayers', m_6095_: 'getEntityType', m_7678_: 'setPositionAndRotation', m_129783_: 'getOverworld' }
  var method = aliases[srg] ? object[aliases[srg]] : undefined
  if (typeof method !== 'function') method = object[mapped]
  if (typeof method !== 'function') method = object[srg]
  if (typeof method !== 'function') throw new Error('Missing method: ' + mapped + ' / ' + srg)
  return method.apply(object, args || [])
}

function fenixFlatWriteStatus() {
  try {
    JsonIO.write('kubejs/fenix_night_spawn_status.json', fenixFlatState)
    delete fenixFlatState.reportError
  } catch (error) {
    if (!fenixFlatState.reportError) console.error('[FenixNightSpawn] Could not save status: ' + String(error))
    fenixFlatState.reportError = String(error)
  }
}

function fenixFlatCheck(id, reason) {
  if (!fenixFlatState.lastChecks[id]) fenixFlatState.lastChecks[id] = {}
  var checks = fenixFlatState.lastChecks[id]
  checks[reason] = (checks[reason] || 0) + 1
}

function fenixFlatField(object, mapped, srg) {
  var value = object[mapped]
  return value === undefined ? object[srg] : value
}

function fenixFlatLoadApi() {
  if (fenixFlatApi !== null) return fenixFlatApi
  var names = {
    BlockPos: 'net.minecraft.core.BlockPos', ResourceLocation: 'net.minecraft.resources.ResourceLocation', Axis: 'net.minecraft.core.Direction$Axis',
    MobCategory: 'net.minecraft.world.entity.MobCategory', LightLayer: 'net.minecraft.world.level.LightLayer',
    Heightmap: 'net.minecraft.world.level.levelgen.Heightmap$Types', GameRules: 'net.minecraft.world.level.GameRules',
    SpawnPlacements: 'net.minecraft.world.entity.SpawnPlacements', SpawnType: 'net.minecraft.world.entity.MobSpawnType',
    NaturalSpawner: 'net.minecraft.world.level.NaturalSpawner', ForgeRegistries: 'net.minecraftforge.registries.ForgeRegistries',
    ForgeEvents: 'net.minecraftforge.event.ForgeEventFactory'
  }
  var api = {}
  Object.keys(names).forEach(function (name) { api[name] = Java.loadClass(names[name]) })
  api.marker = new api.ResourceLocation('fenix_night_spawn', 'enabled.json')
  api.ids = Object.keys(fenixFlatConfig.targets)
  api.types = api.ids.map(function (id) { return api.ForgeRegistries.ENTITY_TYPES.getValue(new api.ResourceLocation(id)) })
  fenixFlatApi = api
  return api
}

function fenixFlatPosition(entity) {
  var pos = { x: Number(fenixFlatCall(entity, 'getX', 'm_20185_')), y: Number(fenixFlatCall(entity, 'getY', 'm_20186_')), z: Number(fenixFlatCall(entity, 'getZ', 'm_20189_')) }
  if (!isFinite(pos.x) || !isFinite(pos.y) || !isFinite(pos.z)) throw new Error('Invalid entity coordinates')
  return pos
}

function fenixFlatDistance(a, b) {
  return (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)
}

function fenixFlatCount(entries, center, id, radius) {
  if (radius === undefined) radius = fenixFlatConfig.countRadius
  var count = 0
  entries.forEach(function (entry) {
    if (entry.id === id && fenixFlatDistance(entry, center) <= radius * radius) count++
  })
  return count
}

function fenixFlatAtSurface(api, level, chunks, point) {
  var call = fenixFlatCall
  var x = Math.floor(point.x)
  var z = Math.floor(point.z)
  if (!call(chunks, 'hasChunk', 'm_5563_', [Math.floor(x / 16), Math.floor(z / 16)])) return false
  var pos = new api.BlockPos(x, Math.floor(point.y), z)
  if (!call(level, 'isPositionEntityTicking', 'm_143340_', [pos])) return false
  var surface = Number(call(level, 'getHeight', 'm_6924_', [api.Heightmap.MOTION_BLOCKING_NO_LEAVES, x, z]))
  if (!isFinite(surface)) throw new Error('Invalid surface height')
  return Math.abs(point.y - surface) <= fenixFlatConfig.surfaceBand
}

function fenixFlatBiomeAllows(api, level, pos, type) {
  var call = fenixFlatCall
  var holder = call(level, 'getBiome', 'm_204166_', [pos])
  var key = call(holder, 'unwrapKey', 'm_203543_')
  if (!key.isPresent()) return false
  var biomeId = String(call(key.get(), 'location', 'm_135782_'))
  if (!api.biomePools[biomeId]) {
    var biome = call(holder, 'value', 'm_203334_')
    var pool = call(call(call(biome, 'getMobSettings', 'm_47518_'), 'getMobs', 'm_151798_', [api.MobCategory.MONSTER]), 'unwrap', 'm_146338_')
    var allowed = {}
    for (var n = 0; n < pool.size(); n++) {
      var entry = pool.get(n)
      if (Number(call(call(entry, 'getWeight', 'm_142631_'), 'asInt', 'm_146281_')) <= 0) continue
      allowed[String(api.ForgeRegistries.ENTITY_TYPES.getKey(fenixFlatField(entry, 'type', 'f_48404_')))] = true
    }
    api.biomePools[biomeId] = allowed
  }
  return api.biomePools[biomeId][String(api.ForgeRegistries.ENTITY_TYPES.getKey(type))] === true
}

function fenixFlatSurfacePoint(api, level, x, y, z) {
  var call = fenixFlatCall
  var pos = new api.BlockPos(x, y, z)
  var state = call(level, 'getBlockState', 'm_8055_', [pos])
  function blockId(blockState) { return String(api.ForgeRegistries.BLOCKS.getKey(call(blockState, 'getBlock', 'm_60734_'))) }
  var id = blockId(state)
  if (id === 'minecraft:powder_snow') return null
  if (id !== 'minecraft:snow') {
    var belowPos = new api.BlockPos(x, y - 1, z)
    var below = call(level, 'getBlockState', 'm_8055_', [belowPos])
    var belowId = blockId(below)
    if (belowId === 'minecraft:powder_snow') return null
    if (belowId !== 'minecraft:snow') return { x: x + 0.5, y: y, z: z + 0.5, pos: pos, snow: false }
    y--
    pos = belowPos
    state = below
  }
  // A snow layer may be at the heightmap coordinate or one block below it.
  // Use the actual collision shape instead of assuming an integer foot height.
  var shape = call(state, 'getCollisionShape', 'm_60812_', [level, pos])
  var top = call(shape, 'isEmpty', 'm_83281_') ? 0 : Number(call(shape, 'max', 'm_83297_', [api.Axis.Y]))
  if (!isFinite(top) || top < 0 || top > 1) return null
  var feetY = y + top
  return { x: x + 0.5, y: feetY, z: z + 0.5, pos: new api.BlockPos(x, Math.floor(feetY), z), snow: true }
}

function fenixFlatTrySpawn(api, level, chunks, random, player, players, type) {
  var call = fenixFlatCall
  var id = String(api.ForgeRegistries.ENTITY_TYPES.getKey(type))
  for (var attempt = 0; attempt < fenixFlatConfig.attempts; attempt++) {
    fenixFlatState.attempts++
    fenixFlatCheck(id, 'attempts')
    var angle = fenixFlatRandom() * 6.283185307179586
    var near = fenixFlatConfig.minDistance
    var far = fenixFlatConfig.maxDistance
    var radius = Math.sqrt(near * near + fenixFlatRandom() * (far * far - near * near))
    var x = Math.floor(player.x + Math.cos(angle) * radius)
    var z = Math.floor(player.z + Math.sin(angle) * radius)
    if (!isFinite(x) || !isFinite(z)) throw new Error('Invalid candidate coordinates')
    if (!call(chunks, 'hasChunk', 'm_5563_', [Math.floor(x / 16), Math.floor(z / 16)])) { fenixFlatCheck(id, 'chunk_unloaded'); continue }
    var y = Number(call(level, 'getHeight', 'm_6924_', [api.Heightmap.MOTION_BLOCKING_NO_LEAVES, x, z]))
    if (!isFinite(y)) throw new Error('Invalid surface height')
    var surface = fenixFlatSurfacePoint(api, level, x, y, z)
    if (surface === null) { fenixFlatCheck(id, 'unsafe_snow_surface'); continue }
    var pos = surface.pos
    if (!call(level, 'isPositionEntityTicking', 'm_143340_', [pos])) { fenixFlatCheck(id, 'chunk_not_ticking'); continue }
    var point = { x: surface.x, y: surface.y, z: surface.z }
    if (surface.snow) fenixFlatCheck(id, 'snow_surface')
    if (fenixFlatDistance(point, player) > far * far) { fenixFlatCheck(id, 'too_far'); continue }
    if (players.some(function (other) { return fenixFlatDistance(point, other) < near * near })) { fenixFlatCheck(id, 'near_player'); continue }
    var shared = call(level, 'getSharedSpawnPos', 'm_220360_')
    var sharedPoint = { x: Number(call(shared, 'getX', 'm_123341_')), y: Number(call(shared, 'getY', 'm_123342_')), z: Number(call(shared, 'getZ', 'm_123343_')) }
    if (fenixFlatDistance(point, sharedPoint) <= 24 * 24) { fenixFlatCheck(id, 'near_world_spawn'); continue }
    // Explicit light checks remain in force even if another mod returns ALLOW.
    if (Number(call(level, 'getBrightness', 'm_45517_', [api.LightLayer.BLOCK, pos])) !== 0) { fenixFlatCheck(id, 'block_light'); continue }
    if (Number(call(level, 'getMaxLocalRawBrightness', 'm_46803_', [pos])) > 7) { fenixFlatCheck(id, 'sky_light'); continue }
    if (!fenixFlatBiomeAllows(api, level, pos, type)) { fenixFlatCheck(id, 'biome_denied'); continue }
    var placement = call(api.SpawnPlacements, 'getPlacementType', 'm_21752_', [type])
    if (!call(api.NaturalSpawner, 'isSpawnPositionOk', 'm_47051_', [placement, level, pos, type])) { fenixFlatCheck(id, 'floor_denied'); continue }
    if (!call(api.SpawnPlacements, 'checkSpawnRules', 'm_217074_', [type, level, api.SpawnType.NATURAL, pos, random])) { fenixFlatCheck(id, 'spawn_rules_denied'); continue }
    var mob = call(type, 'create', 'm_20615_', [level])
    if (mob === null) { fenixFlatCheck(id, 'create_failed'); continue }
    call(mob, 'moveTo', 'm_7678_', [point.x, point.y, point.z, fenixFlatRandom() * 360, 0])
    if (!call(level, 'noCollision', 'm_45786_', [mob])) { fenixFlatCheck(id, 'collision'); continue }
    if (!call(mob, 'checkSpawnObstruction', 'm_6914_', [level])) { fenixFlatCheck(id, 'obstruction'); continue }
    if (!api.ForgeEvents.checkSpawnPosition(mob, level, api.SpawnType.NATURAL)) { fenixFlatCheck(id, 'forge_denied'); continue }
    api.ForgeEvents.onFinalizeSpawn(mob, level, call(level, 'getCurrentDifficultyAt', 'm_6436_', [pos]), api.SpawnType.NATURAL, null, null)
    if (mob.isSpawnCancelled()) { fenixFlatCheck(id, 'finalize_cancelled'); continue }
    // Finalization may change slime size, so check the final body as well.
    if (!call(level, 'noCollision', 'm_45786_', [mob]) || !call(mob, 'checkSpawnObstruction', 'm_6914_', [level])) { fenixFlatCheck(id, 'final_body_blocked'); continue }
    call(level, 'addFreshEntityWithPassengers', 'm_47205_', [mob])
    if (!mob.isAddedToWorld()) { fenixFlatCheck(id, 'join_cancelled'); continue }
    fenixFlatCheck(id, 'spawned')
    return point
  }
  return null
}

function fenixFlatStep(server) {
  fenixFlatState.lastChecks = {}
  fenixFlatState.nearPlayers = []
  var api = fenixFlatLoadApi()
  var call = fenixFlatCall
  var resources = call(server, 'getResourceManager', 'm_177941_')
  if (!call(resources, 'getResource', 'm_213713_', [api.marker]).isPresent()) { fenixFlatState.status = 'datapack_absent'; return }
  var level = call(server, 'overworld', 'm_129783_')
  var chunks = call(level, 'getChunkSource', 'm_7726_')
  fenixFlatState.generator = String(call(chunks, 'getGenerator', 'm_8481_').getClass().getName())
  if (String(call(level, 'getDifficulty', 'm_46791_')) === 'PEACEFUL') { fenixFlatState.status = 'peaceful'; return }
  if (!call(call(level, 'getGameRules', 'm_46469_'), 'getBoolean', 'm_46207_', [fenixFlatField(api.GameRules, 'RULE_DOMOBSPAWNING', 'f_46134_')])) { fenixFlatState.status = 'gamerule_disabled'; return }
  var time = Number(call(level, 'getDayTime', 'm_46468_')) % 24000
  fenixFlatState.dayTime = time
  if (time < 13000 || time >= 23000) { fenixFlatState.status = 'daytime'; return }
  var allPlayers = []
  var players = []
  var list = call(level, 'players', 'm_6907_')
  for (var i = 0; i < list.size(); i++) {
    var entity = list.get(i)
    if (!call(entity, 'isSpectator', 'm_5833_') && call(entity, 'isAlive', 'm_6084_')) {
      var player = fenixFlatPosition(entity)
      allPlayers.push(player)
      if (fenixFlatAtSurface(api, level, chunks, player)) players.push(player)
    }
  }
  if (!players.length) { fenixFlatState.status = allPlayers.length ? 'no_surface_players' : 'no_players'; return }
  api.biomePools = {}
  var entries = []
  var total = 0
  var iterator = call(level, 'getAllEntities', 'm_8583_').iterator()
  while (iterator.hasNext()) {
    var mob = iterator.next()
    var type = call(mob, 'getType', 'm_6095_')
    if (!call(type, 'getCategory', 'm_20674_').equals(api.MobCategory.MONSTER) || !call(mob, 'isAlive', 'm_6084_')) continue
    total++
    var id = String(api.ForgeRegistries.ENTITY_TYPES.getKey(type))
    if (api.ids.indexOf(id) < 0) continue
    var entry = fenixFlatPosition(mob)
    if (!fenixFlatAtSurface(api, level, chunks, entry)) continue
    entry.id = id
    entries.push(entry)
  }
  fenixFlatState.status = 'active'
  fenixFlatState.loadedMonsters = total
  fenixFlatState.players = players.length
  fenixFlatState.targets = fenixFlatConfig.targets
  fenixFlatState.countRadius = fenixFlatConfig.countRadius
  var random = call(level, 'getRandom', 'm_213780_')
  for (var p = 0; p < players.length; p++) {
    for (var t = 0; t < api.ids.length; t++) {
      if (total >= fenixFlatConfig.globalSafetyPerPlayer * players.length) { fenixFlatState.status = 'safety_limit'; break }
      if (fenixFlatCount(entries, players[p], api.ids[t]) >= fenixFlatConfig.targets[api.ids[t]]) { fenixFlatCheck(api.ids[t], 'at_target'); continue }
      var added = fenixFlatTrySpawn(api, level, chunks, random, players[p], allPlayers, api.types[t])
      if (added === null) continue
      added.id = api.ids[t]
      entries.push(added)
      total++
      fenixFlatState.spawned++
      fenixFlatState.spawnedByType[added.id] = (fenixFlatState.spawnedByType[added.id] || 0) + 1
    }
  }
  fenixFlatState.loadedMonsters = total
  fenixFlatState.nearPlayers = players.map(function (player) {
    var report = { x: player.x, y: player.y, z: player.z, within80: {} }
    api.ids.forEach(function (id) {
      var name = id.substring(10)
      report[name] = fenixFlatCount(entries, player, id)
      report.within80[name] = fenixFlatCount(entries, player, id, 80)
    })
    return report
  })
  fenixFlatState.lastActive = { dayTime: time, status: fenixFlatState.status, loadedMonsters: total, nearPlayers: fenixFlatState.nearPlayers, checks: fenixFlatState.lastChecks, biomePools: api.biomePools }
}

ServerEvents.loaded(function () {
  fenixFlatStopped = false
  fenixFlatTicks = 0
  fenixFlatApi = null
  fenixFlatState = { version: 4, status: 'waiting', spawned: 0, attempts: 0, errors: 0, spawnedByType: {}, lastChecks: {} }
})

ServerEvents.tick(function (event) {
  if (fenixFlatStopped || ++fenixFlatTicks % 20 !== 0) return
  try {
    fenixFlatStep(event.server)
    if (fenixFlatTicks % 1200 === 0 && fenixFlatState.status !== 'datapack_absent') {
      console.info('[FenixNightSpawn] ' + JSON.stringify(fenixFlatState))
      fenixFlatWriteStatus()
    }
  } catch (error) {
    fenixFlatStopped = true
    fenixFlatState.status = 'error'
    fenixFlatState.errors++
    fenixFlatState.error = String(error)
    console.error('[FenixNightSpawn] Stopped safely: ' + String(error))
    fenixFlatWriteStatus()
  }
})

ServerEvents.commandRegistry(function (event) {
  ;['nightspawnstatus', 'flatspawnstatus'].forEach(function (command) {
  event.register(event.commands.literal(command)
    .requires(function (source) { return fenixFlatCall(source, 'hasPermission', 'm_6761_', [2]) })
    .executes(function (context) {
      fenixFlatWriteStatus()
      fenixFlatCall(context.source, 'sendSystemMessage', 'm_243053_', [Text.of(JSON.stringify(fenixFlatState))])
      return fenixFlatState.errors ? 0 : 1
    }))
  })
})
