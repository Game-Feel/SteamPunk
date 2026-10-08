// Minecraft 1.20.1 with KubeJS 2001.6.5.
// This command reads spawn state without creating or removing entities.
var fenixSpawnCheckLastRun = {}

function fenixSpawnCall(object, mapped, srg, args) {
  var aliases = { m_6907_: 'getPlayers', m_6095_: 'getEntityType', m_46472_: 'getDimensionKey' }
  var method = aliases[srg] ? object[aliases[srg]] : undefined
  if (typeof method !== 'function') method = object[mapped]
  if (typeof method !== 'function') method = object[srg]
  if (typeof method !== 'function') throw new Error('Missing method: ' + mapped + ' / ' + srg)
  return method.apply(object, args || [])
}

function fenixSpawnCoordinate(origin, axis, srgMethod, srgField) {
  var value = origin[axis]
  if (typeof value === 'function') value = value.call(origin)
  else if (value === undefined && typeof origin[srgMethod] === 'function') value = origin[srgMethod]()
  else if (value === undefined) value = origin[srgField]
  value = Number(value)
  if (!isFinite(value)) throw new Error('Invalid coordinate: ' + axis)
  return value
}

function fenixSpawnField(object, mapped, srg) {
  var value = object[mapped]
  return value === undefined ? object[srg] : value
}

function fenixSpawnFindings(report) {
  var findings = []
  if (report.doMobSpawning === false) findings.push('Естественный спаун выключен правилом doMobSpawning.')
  if (report.difficulty === 'PEACEFUL') findings.push('Мир находится на мирной сложности.')
  if (report.monsterCount !== undefined && report.nominalMonsterCap > 0 && report.monsterCount >= report.nominalMonsterCap) {
    findings.push('Достигнут базовый лимит монстров. Лунные события могут менять этот лимит. Состав существ записан в отчёт.')
  }
  if (report.samples && report.samples.length) {
    var dark = report.samples.filter(function (s) { return s.blockLight === 0 && s.effectiveLight <= 7 })
    if (!dark.length) findings.push('Среди проверенных точек нет тёмных мест для обычных ночных монстров.')
    var withVanilla = report.samples.filter(function (s) { return s.vanillaWeight > 0 })
    if (!withVanilla.length) findings.push('В проверенных биомах отсутствуют зомби, скелеты, криперы и пауки в списке естественного спауна.')
    var diluted = report.samples.filter(function (s) { return s.vanillaWeight > 0 && s.vanillaWeight / s.totalWeight < 0.1 })
    if (diluted.length) findings.push('В части точек доля обычных монстров в списке спауна меньше 10 процентов.')
  }
  if (!findings.length) findings.push('Явного запрета по этим данным нет. Нужны сравнение ночных замеров и проверка правил на сервере.')
  return findings
}

function fenixSpawnReport(source) {
  var call = fenixSpawnCall
  var field = fenixSpawnField
  var BlockPos = Java.loadClass('net.minecraft.core.BlockPos')
  var MobCategory = Java.loadClass('net.minecraft.world.entity.MobCategory')
  var LightLayer = Java.loadClass('net.minecraft.world.level.LightLayer')
  var Heightmap = Java.loadClass('net.minecraft.world.level.levelgen.Heightmap$Types')
  var GameRules = Java.loadClass('net.minecraft.world.level.GameRules')
  var ForgeRegistries = Java.loadClass('net.minecraftforge.registries.ForgeRegistries')
  var level = call(source, 'getLevel', 'm_81372_')
  var origin = call(source, 'getPosition', 'm_81371_')
  var x = Math.floor(fenixSpawnCoordinate(origin, 'x', 'm_7096_', 'f_82479_'))
  var z = Math.floor(fenixSpawnCoordinate(origin, 'z', 'm_7094_', 'f_82481_'))
  var chunkSource = call(level, 'getChunkSource', 'm_7726_')
  var report = { version: 3, errors: [], samples: [], biomePools: {}, entities: [] }

  function section(name, action) {
    try { action() } catch (error) { report.errors.push(name + ': ' + String(error)) }
  }

  section('world', function () {
    report.dimension = String(call(call(level, 'dimension', 'm_46472_'), 'location', 'm_135782_'))
    report.generator = String(call(chunkSource, 'getGenerator', 'm_8481_').getClass().getName())
    report.minBuildHeight = Number(call(level, 'getMinBuildHeight', 'm_141937_'))
    report.difficulty = String(call(level, 'getDifficulty', 'm_46791_'))
    report.dayTime = Number(call(level, 'getDayTime', 'm_46468_')) % 24000
    report.doMobSpawning = Boolean(call(call(level, 'getGameRules', 'm_46469_'), 'getBoolean', 'm_46207_', [field(GameRules, 'RULE_DOMOBSPAWNING', 'f_46134_')]))
    report.origin = { x: x, y: fenixSpawnCoordinate(origin, 'y', 'm_7098_', 'f_82480_'), z: z }
    report.playerCount = call(level, 'players', 'm_6907_').size()
  })

  section('cap', function () {
    var state = call(chunkSource, 'getLastSpawnState', 'm_8485_')
    if (state === null) { report.spawnState = 'unavailable'; return }
    report.spawnableChunks = Number(call(state, 'getSpawnableChunkCount', 'm_47126_'))
    report.monsterCount = Number(call(state, 'getMobCategoryCounts', 'm_47148_').getInt(MobCategory.MONSTER))
    report.nominalMonsterCap = Math.floor(Number(call(MobCategory.MONSTER, 'getMaxInstancesPerChunk', 'm_21608_')) * report.spawnableChunks / 289)
    report.capNote = 'Vanilla baseline. Lunar events and local player caps may differ.'
  })

  section('entities', function () {
    var counts = {}
    var iterator = call(level, 'getAllEntities', 'm_8583_').iterator()
    while (iterator.hasNext()) {
      var entity = iterator.next()
      var type = call(entity, 'getType', 'm_6095_')
      if (!call(type, 'getCategory', 'm_20674_').equals(MobCategory.MONSTER)) continue
      var id = String(ForgeRegistries.ENTITY_TYPES.getKey(type))
      counts[id] = (counts[id] || 0) + 1
    }
    report.entities = Object.keys(counts).map(function (id) { return { id: id, count: counts[id] } })
    report.entities.sort(function (a, b) { return b.count - a.count })
    report.entityCountNote = 'Includes persistent entities. The spawn state count above is authoritative for the vanilla global cap.'
  })

  section('samples', function () {
    var offsets = [[32, 0], [0, 32], [-32, 0], [0, -32], [48, 48], [-48, 48], [48, -48], [-48, -48], [96, 0], [0, 96], [-96, 0], [0, -96]]
    for (var i = 0; i < offsets.length; i++) {
      var px = x + offsets[i][0]
      var pz = z + offsets[i][1]
      if (!call(chunkSource, 'hasChunk', 'm_5563_', [Math.floor(px / 16), Math.floor(pz / 16)])) continue
      var surface = Number(call(level, 'getHeight', 'm_6924_', [Heightmap.MOTION_BLOCKING_NO_LEAVES, px, pz]))
      for (var dy = 0; dy >= -1; dy--) {
        var pos = new BlockPos(px, surface + dy, pz)
        var holder = call(level, 'getBiome', 'm_204166_', [pos])
        var biome = call(holder, 'value', 'm_203334_')
        var key = call(holder, 'unwrapKey', 'm_203543_')
        var biomeId = key.isPresent() ? String(call(key.get(), 'location', 'm_135782_')) : String(holder)
        if (!report.biomePools[biomeId]) {
          var pool = call(call(call(biome, 'getMobSettings', 'm_47518_'), 'getMobs', 'm_151798_', [MobCategory.MONSTER]), 'unwrap', 'm_146338_')
          var entries = []
          for (var n = 0; n < pool.size(); n++) {
            var entry = pool.get(n)
            entries.push({
              id: String(ForgeRegistries.ENTITY_TYPES.getKey(field(entry, 'type', 'f_48404_'))),
              weight: Number(call(call(entry, 'getWeight', 'm_142631_'), 'asInt', 'm_146281_'))
            })
          }
          report.biomePools[biomeId] = entries
        }
        var vanillaWeight = 0
        var totalWeight = 0
        report.biomePools[biomeId].forEach(function (entry) {
          totalWeight += entry.weight
          if (['minecraft:zombie', 'minecraft:skeleton', 'minecraft:creeper', 'minecraft:spider', 'minecraft:stray', 'minecraft:husk'].indexOf(entry.id) >= 0) vanillaWeight += entry.weight
        })
        report.samples.push({
          x: px, y: surface + dy, z: pz, biome: biomeId,
          block: String(call(level, 'getBlockState', 'm_8055_', [pos])),
          floor: String(call(level, 'getBlockState', 'm_8055_', [new BlockPos(px, surface + dy - 1, pz)])),
          blockLight: Number(call(level, 'getBrightness', 'm_45517_', [LightLayer.BLOCK, pos])),
          skyLight: Number(call(level, 'getBrightness', 'm_45517_', [LightLayer.SKY, pos])),
          effectiveLight: Number(call(level, 'getMaxLocalRawBrightness', 'm_46803_', [pos])),
          vanillaWeight: vanillaWeight, totalWeight: totalWeight
        })
      }
    }
  })
  report.findings = fenixSpawnFindings(report)
  return report
}

ServerEvents.commandRegistry(function (event) {
  event.register(event.commands.literal('spawncheck')
    .requires(function (source) { return fenixSpawnCall(source, 'hasPermission', 'm_6761_', [2]) })
    .executes(function (context) {
      var source = context.source
      function tell(message) { fenixSpawnCall(source, 'sendSystemMessage', 'm_243053_', [Text.of(message)]) }
      var key = String(fenixSpawnCall(source, 'getTextName', 'm_81368_'))
      var now = Date.now()
      if (fenixSpawnCheckLastRun[key] && now - fenixSpawnCheckLastRun[key] < 10000) {
        tell('Подождите 10 секунд перед следующим замером.')
        return 0
      }
      fenixSpawnCheckLastRun[key] = now
      try {
        var report = fenixSpawnReport(source)
        console.info('[FenixSpawnCheck] ' + JSON.stringify(report))
        JsonIO.write('kubejs/fenix_spawn_report.json', report)
        tell('Отчёт сохранён: kubejs/fenix_spawn_report.json')
        tell('Время: ' + report.dayTime + '. Монстры: ' + report.monsterCount + '. Базовый лимит: ' + report.nominalMonsterCap + '.')
        report.findings.forEach(tell)
        if (report.errors.length) tell('Часть проверок не выполнена. Ошибки записаны в отчёт.')
        return report.errors.length ? 0 : 1
      } catch (error) {
        console.error('[FenixSpawnCheck] ' + String(error))
        tell('Не удалось собрать отчёт: ' + String(error))
        return 0
      }
    }))
})
