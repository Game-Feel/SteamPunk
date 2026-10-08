function writeJson(path, value) {
  JsonIO.write(path, value)
}

function safeCall(fn, fallback) {
  try {
    const value = fn()
    if (value == null) return fallback
    return value
  } catch (e) {
    return fallback
  }
}

function safeString(fn, fallback) {
  try {
    const value = fn()
    if (value == null) return fallback
    return '' + value
  } catch (e) {
    return fallback
  }
}

function addToIndex(index, key, recipeId) {
  if (!key) return
  key = String(key)
  if (!index[key]) index[key] = []
  if (!index[key].includes(recipeId)) index[key].push(recipeId)
}

function uniqueSorted(list) {
  return Array.from(new Set(list)).sort()
}

function matchFirst(text, regex, fallback) {
  const found = String(text).match(regex)
  if (found && found[1]) return String(found[1])
  return fallback
}

function extractKeys(text) {
  const source = String(text || '')
  const list = []

  let found

  const quotedTag = /"tag"\s*:\s*"([a-z0-9_.-]+:[a-z0-9_./-]+)"/gi
  while ((found = quotedTag.exec(source)) !== null) {
    list.push('#' + found[1])
  }

  const quotedFluid = /"fluid"\s*:\s*"([a-z0-9_.-]+:[a-z0-9_./-]+)"/gi
  while ((found = quotedFluid.exec(source)) !== null) {
    list.push('fluid:' + found[1])
  }

  const genericId = /#?[a-z0-9_.-]+:[a-z0-9_./-]+/gi
  while ((found = genericId.exec(source)) !== null) {
    let value = String(found[0])
    if (value.startsWith('type:')) continue
    if (value.startsWith('id:')) value = value.substring(3)
    list.push(value)
  }

  return uniqueSorted(list)
}

function extractType(recipe, raw, recipeText) {
  let type = matchFirst(raw, /"type"\s*:\s*"([^"]+)"/, '')
  if (type) return type

  type = matchFirst(recipeText, /\[([a-z0-9_.-]+:[a-z0-9_./-]+)\]/i, '')
  if (type) return type

  type = safeString(() => recipe.type, '')
  if (type && type !== '[object Object]') return type

  type = safeString(() => recipe.getType(), '')
  if (type && type !== '[object Object]') return type

  return 'unknown'
}

function splitFromTo(text) {
  const s = String(text || '')
  const marker = '] -> ['
  const pos = s.indexOf(marker)

  if (pos < 0) {
    return {
      left: s,
      right: ''
    }
  }

  return {
    left: s.substring(0, pos + 1),
    right: '[' + s.substring(pos + marker.length)
  }
}

function getRecipeId(recipe, index) {
  let id = safeString(() => recipe.getId(), '')
  if (id && id !== '[object Object]') return id

  id = safeString(() => recipe.id, '')
  if (id && id !== '[object Object]') return id

  const text = safeString(() => recipe.toString(), '')
  const fromText = matchFirst(text, /^([a-z0-9_.-]+:[^\[]+)\[/i, '')
  if (fromText) return fromText

  return 'unknown:recipe_' + index
}

function getRecipeText(recipe) {
  let text = safeString(() => recipe.getFromToString(), '')
  if (text && text !== '[object Object]') return text

  text = safeString(() => recipe.toString(), '')
  if (text && text !== '[object Object]') return text

  return ''
}

function getRawJsonText(recipe) {
  let raw = safeString(() => recipe.json.toString(), '')
  if (raw && raw !== '[object Object]' && raw !== 'undefined' && raw !== 'null') return raw

  raw = safeString(() => recipe.originalJson.toString(), '')
  if (raw && raw !== '[object Object]' && raw !== 'undefined' && raw !== 'null') return raw

  raw = safeString(() => recipe.json, '')
  if (raw && raw !== '[object Object]' && raw !== 'undefined' && raw !== 'null') return raw

  raw = safeString(() => recipe.originalJson, '')
  if (raw && raw !== '[object Object]' && raw !== 'undefined' && raw !== 'null') return raw

  return ''
}

function chunkWrite(baseName, list, chunkSize) {
  let part = 1
  for (let i = 0; i < list.length; i += chunkSize) {
    const chunk = list.slice(i, i + chunkSize)
    const partName = String(part).padStart(3, '0')
    writeJson('kubejs/fenix_dump/' + baseName + '_part_' + partName + '.json', chunk)
    part++
  }

  return part - 1
}

ServerEvents.recipes(event => {
  const recipesIndex = []
  const recipesFullText = []
  const objectDiagnostics = []
  const byType = {}
  const byInput = {}
  const byOutput = {}
  const byAnyItemOrTag = {}

  let seen = 0
  let dumped = 0
  let hardErrors = 0

  event.forEachRecipe({}, recipe => {
    seen++

    try {
      const recipeId = getRecipeId(recipe, seen)
      const recipeText = getRecipeText(recipe)
      const rawJsonText = getRawJsonText(recipe)
      const type = extractType(recipe, rawJsonText, safeString(() => recipe.toString(), ''))

      const fromTo = splitFromTo(recipeText)
      const inputKeys = extractKeys(fromTo.left)
      const outputKeys = extractKeys(fromTo.right)
      const rawKeys = extractKeys(rawJsonText)
      const allKeys = uniqueSorted(inputKeys.concat(outputKeys).concat(rawKeys))

      const indexEntry = {
        id: recipeId,
        type: type,
        inputs: inputKeys,
        outputs: outputKeys,
        all_items_tags_fluids_in_recipe: allKeys,
        from_to: recipeText
      }

      recipesIndex.push(indexEntry)

      recipesFullText.push({
        id: recipeId,
        type: type,
        inputs: inputKeys,
        outputs: outputKeys,
        all_items_tags_fluids_in_recipe: allKeys,
        from_to: recipeText,
        raw_json_text: rawJsonText
      })

      byType[type] = (byType[type] || 0) + 1

      inputKeys.forEach(input => addToIndex(byInput, input, recipeId))
      outputKeys.forEach(output => addToIndex(byOutput, output, recipeId))
      allKeys.forEach(key => addToIndex(byAnyItemOrTag, key, recipeId))

      if (objectDiagnostics.length < 30) {
        objectDiagnostics.push({
          id: recipeId,
          type: type,
          recipe_toString: safeString(() => recipe.toString(), ''),
          from_to: recipeText,
          raw_json_text_start: rawJsonText.substring(0, 1500),
          object_keys: safeCall(() => Object.keys(recipe), []),
          has_getId: safeString(() => typeof recipe.getId, ''),
          has_getFromToString: safeString(() => typeof recipe.getFromToString, ''),
          has_json: safeString(() => typeof recipe.json, ''),
          has_originalJson: safeString(() => typeof recipe.originalJson, ''),
          has_inputValues: safeString(() => typeof recipe.inputValues, ''),
          has_outputValues: safeString(() => typeof recipe.outputValues, '')
        })
      }

      dumped++
    } catch (e) {
      hardErrors++

      if (objectDiagnostics.length < 30) {
        objectDiagnostics.push({
          hard_error: String(e),
          recipe_toString: safeString(() => recipe.toString(), ''),
          object_keys: safeCall(() => Object.keys(recipe), [])
        })
      }
    }
  })

  recipesIndex.sort((a, b) => a.id.localeCompare(b.id))
  recipesFullText.sort((a, b) => a.id.localeCompare(b.id))

  const parts = chunkWrite('recipes_full_text', recipesFullText, 500)

  writeJson('kubejs/fenix_dump/diagnostics.json', {
    event_fired: true,
    recipes_seen_by_forEachRecipe: seen,
    recipes_dumped: dumped,
    hard_errors: hardErrors,
    full_text_parts: parts,
    mode: 'v4_getFromToString_plus_rawText_fallback'
  })

  writeJson('kubejs/fenix_dump/recipes_index.json', recipesIndex)
  writeJson('kubejs/fenix_dump/recipes_by_type.json', byType)
  writeJson('kubejs/fenix_dump/recipes_by_input.json', byInput)
  writeJson('kubejs/fenix_dump/recipes_by_output.json', byOutput)
  writeJson('kubejs/fenix_dump/recipes_by_any_item_or_tag.json', byAnyItemOrTag)
  writeJson('kubejs/fenix_dump/recipe_object_diagnostics.json', objectDiagnostics)

  console.log('[FENIX DUMP V4] Recipe dump created in kubejs/fenix_dump')
  console.log('[FENIX DUMP V4] Recipes seen: ' + seen)
  console.log('[FENIX DUMP V4] Recipes dumped: ' + dumped)
  console.log('[FENIX DUMP V4] Hard errors: ' + hardErrors)
})
