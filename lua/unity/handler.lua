local utils = require("unity.utils")
local config = require("unity.config")
require("lfs")

local XmlCsprojHandler = {}
XmlCsprojHandler.__index = XmlCsprojHandler

function XmlCsprojHandler:getLspName()
	return self.lspName
end

function XmlCsprojHandler:getRoot()
	return self.rootFolder
end

function XmlCsprojHandler:updateRoot()
	self.hasCSProjectUnityCapability = false
	self.rootFolder = utils.findRootFolder()
end

-- Função para criar um novo objeto
-- Function to create a new object
function XmlCsprojHandler:new()
	local obj = {
		rootFolder = nil, -- Variável da instância / Instance variable
		hasCSProjectUnityCapability = false,
		lspName = "roslyn", -- "omnisharp",
	}
	setmetatable(obj, self)
	self.__index = self
	return obj
end

-- Função para carregar o arquivo .csproj
-- Function to load the .csproj file
function XmlCsprojHandler:load(filename)
	local file = io.open(filename, "r")
	if not file then
		return false, "File not found"
	end
	self.content[file][filename] = file:read("*a")
	file:close()
	return true
end

-- Função para salvar o arquivo .csproj
-- Function to save the .csproj file
function XmlCsprojHandler:save()
	for filename in lfs.dir(self.rootFolder) do
		if filename:match("%.csproj$") then
			local file = io.open(self.rootFolder .. filename, "w")
			if not file then
				return false, "Cannot open file for writing"
			end
			file:write(self.content[file][filename])
			file:close()
		end
	end
	return true
end

-- Função para checar se o projeto é um Unity Project
-- Function to check if the project is a Unity Project
function XmlCsprojHandler:validateProject()
	-- Verifica se o RootFolder está definido
	-- Checks if the RootFolder is set
	if not self.rootFolder then
		return false, "No Unity Project found"
	end

	if self.hasCSProjectUnityCapability then
		return true, "Unity CsProject detected at " .. self.rootFolder
	end

	-- Caminho do Assembly-CSharp.csproj
	-- Path of Assembly-CSharp.csproj
	for file in lfs.dir(self.rootFolder) do
		if file:match("%.csproj$") then
			local filepath = self.rootFolder .. file
			-- Verifica se o arquivo existe
			-- Checks if the file exists
			if not utils.fileExists(filepath) then
				return false, "No CsProject found, regenerate project files in Unity"
			end

			-- Carrega o XML do arquivo .csproj
			-- Loads the XML from the .csproj file
			if not self:load(filepath) then
				return false, "Failed to load the Assembly-CSharp.csproj file"
			end

			-- Verifica se o projeto é do Unity
			-- Checks if the project is Unity
			self.hasCSProjectUnityCapability = self:checkProjectCapability(file, "Unity")
		end
	end

	return self.hasCSProjectUnityCapability, "This is an Unity Project ready to sync"
end

-- Função para checar a tag ProjectCapability e seu atributo
-- Function to check the ProjectCapability tag and its attribute
function XmlCsprojHandler:checkProjectCapability(file, attribute)
	local pattern = '<ProjectCapability.-Include="' .. attribute .. '".-/>'
	if self.content[file]:match(pattern) then
		return true
	end
	return false
end

-- Função para adicionar uma nova Compile tag
-- Function to add a new Compile tag
function XmlCsprojHandler:addCompileTag(file, value)
	-- Protege o valor para uso em pattern
	-- Protects value for use in pattern
	local escapedValue = value:gsub("([%.%+%-%*%?%^%$%(%)%[%]%%])", "%%%1")
	local existingPattern = "<Compile%s+Include%s*=%s*[\"']" .. escapedValue .. "[\"']%s*/?>"

	-- Evita duplicação
	-- Avoids duplication
	if self.content[file]:match(existingPattern) then
		return false, "[NvimUnity] Script already added in Unity project"
	end

	-- Se placeholder existe, insere nele
	-- If placeholder exists, insert it into it
	local placeholderPattern = "<!%-%- {{COMPILE_INCLUDES}} %-%->"
	if self.content[file]:match(placeholderPattern) then
		local newLine = '    <Compile Include="' .. value .. '" />\n    <!-- {{COMPILE_INCLUDES}} -->'
		self.content[file] = self.content[file]:gsub(placeholderPattern, newLine, 1)
		return true, "[NvimUnity] Script added to Unity project"
	end

	-- Se não existe placeholder, adiciona bloco novo com placeholder e tag
	-- If there is no placeholder, add new block with placeholder and tag
	local newItemGroup = "  <ItemGroup>\n"
		.. "<!-- Auto-generated block: do not modify manually or remove these commented lines -->\n"
		.. "<!-- {{COMPILE_INCLUDES}} -->\n"
		.. '    <Compile Include="'
		.. value
		.. '" />\n'
		.. "  </ItemGroup>"

	-- Extrai a tag <Project>
	-- Extract the tag
	local openTag, innerContent, closeTag = self.content[file]:match("(<Project.-\n)(.-)(</Project>)")
	if not openTag then
		return false, "[NvimUnity] <Project> tag not found"
	end

	-- Divide em linhas para inserir corretamente
	-- Splits into rows to insert correctly
	local lines = {}
	for line in innerContent:gmatch("([^\n]*)\n?") do
		table.insert(lines, line)
	end

	-- Conta filhos diretos
	-- Direct children account
	local depth, childrenCount, insertLine = 0, 0, #lines + 1
	for i, line in ipairs(lines) do
		local open = line:match("^%s*<([%w%.%-]+)[^>/]*>$")
		local selfClosing = line:match("^%s*<([%w%.%-]+)[^>]-/>%s*$")
		local close = line:match("^%s*</([%w%.%-]+)>%s*$")

		if selfClosing and depth == 0 then
			childrenCount = childrenCount + 1
		elseif open then
			if depth == 0 then
				childrenCount = childrenCount + 1
			end
			depth = depth + 1
		elseif close then
			depth = math.max(0, depth - 1)
		end

		if childrenCount == 10 and depth == 0 then
			insertLine = i + 1
			break
		end
	end

	-- Insere o novo bloco na posição definida
	-- Inserts the new block at the defined position
	table.insert(lines, insertLine, newItemGroup)
	self.content[file] = openTag .. table.concat(lines, "\n") .. "\n" .. closeTag

	return true, "[NvimUnity] Script added and placeholder created"
end

-- Função para adicionar ou modificar a tag Compile
-- Function to add or modify the Compile tag
function XmlCsprojHandler:updateCompileTags(file, changes)
	-- Expressão para capturar os <ItemGroup> com tags <Compile>
	-- Expression to capture the <ItemGroup> tagged with <Compile>
	local itemGroupPattern = "(<ItemGroup>.-</ItemGroup>)"
	local updated = {}

	-- Processa cada grupo separadamente
	-- Processes each group separately
	self.content[file] = self.content[file]:gsub(itemGroupPattern, function(itemGroup)
		-- Processa apenas <ItemGroup> que contêm <Compile>
		-- Processes only <ItemGruop> that contain <Compile>
		if itemGroup:match("<Compile") then
			-- Modifica apenas os valores dentro deste grupo
			-- Modify only the values within this group
			for _, change in ipairs(changes) do
				if type(change.old) == "string" and type(change.new) == "string" then
					local oldValue = change.old:gsub("([%.%+%-%*%?%^%$%(%)%[%]%%])", "%%%1")
					local newValue = change.new

					local newGroup, count = itemGroup:gsub(
						"(<Compile%s+Include%s*=%s*[\"'])" .. oldValue .. "([\"'])",
						"%1" .. newValue .. "%2",
						1
					)

					if count > 0 then
						itemGroup = newGroup
						table.insert(updated, { old = change.old, new = newValue })
					end
				end
			end
		end
		return itemGroup
	end)

	return updated -- opcional: retorna as alterações feitas
	-- Optional: Returns the changes you made
end

-- Função para remover uma tag Compile
-- Function to remove a Compile tag
function XmlCsprojHandler:removeCompileTag(file, attribute)
	local modified = false

	-- Escapa caracteres especiais para regex do Lua
	-- Escapes special characters for Lua regex
	local escapedAttribute = attribute:gsub("([%.%+%-%*%?%^%$%(%)%[%]%%])", "%%%1")

	-- Atualiza apenas os ItemGroups que contêm <Compile>
	-- Updates only ItemGroups that contain
	self.content[file] = self.content[file]:gsub("(<ItemGroup>.-</ItemGroup>)", function(itemGroup)
		if not itemGroup:match("<Compile") then
			return itemGroup -- Ignora ItemGroups sem <Compile> / Ignores ItemGroups without <Compile>
		end

		local lines = {} -- Guarda as linhas atualizadas do ItemGroup / Saves the updated ItemGroup rows
		for line in itemGroup:gmatch("[^\r\n]+") do
			if not line:match("<Compile%s+Include%s*=%s*['\"]" .. escapedAttribute .. "['\"]") then
				table.insert(lines, line) -- Mantém linhas que não precisam ser removidas / Maintains lines that don't need to be removed
			else
				modified = true -- Indica que houve uma remoção / Indicates that there has been a removal
			end
		end

		-- Remove o ItemGroup inteiro se ele ficou apenas com <ItemGroup>...</ItemGroup>
		-- Removes the entire ItemGroup if it was left with only <ItemGroup>...</ItemGroup>
		if #lines == 2 then
			return ""
		end

		return table.concat(lines, "\n")
	end)

	return modified
end

-- Função para remover uma ou varias Compile tags pelo nome da pasta
-- Function to remove one or multiple Compile tags by folder name
function XmlCsprojHandler:removeCompileTagsByFolder(file, folderpath)
	local modified = false

	-- Escapa caracteres especiais para padrões Lua
	-- Escapes special characters for Moon patterns
	local escapedFolderPath = folderpath:gsub("([%.%+%-%*%?%^%$%(%)%[%]%%])", "%%%1")

	-- Atualiza apenas os ItemGroups que contêm <Compile>
	-- Updates only ItemGroups that contain <Compile>
	self.content[file] = self.content[file]:gsub("(<ItemGroup>.-</ItemGroup>)", function(itemGroup)
		if not itemGroup:match("<Compile") then
			return itemGroup -- Ignora ItemGroups sem <Compile> / Ignores ItemGroups without <Compile>
		end

		local lines = {} -- Guarda as linhas atualizadas do ItemGroup / Saves the updated ItemGroup rows
		for line in itemGroup:gmatch("[^\r\n]+") do
			-- Remove apenas as tags <Compile> cujo caminho começa com folderpath
			-- Removes only tags whose path begins with folderpath
			if not line:match("<Compile%s+Include%s*=%s*['\"]" .. escapedFolderPath .. "[^'\"]*['\"]") then
				table.insert(lines, line) -- Mantém linhas que não precisam ser removidas / Maintains lines that don't need to be removed
			else
				modified = true -- Indica que houve remoção / Indicates that there has been a removal
			end
		end

		-- Remove o ItemGroup inteiro se ele ficou apenas com <ItemGroup>...</ItemGroup>
		-- Removes the entire ItemGroup if it was left with only <ItemGroup>...</ItemGroup>
		if #lines == 2 then
			return ""
		end

		return table.concat(lines, "\n")
	end)

	return modified
end

-- Função para remover all Compile tags e preencher com uma nova lista
-- Function to remove all Compile tags and populate with a new list
function XmlCsprojHandler:resetCompileTags(file)
	local files = utils.getCSFilesInFolder(self.rootFolder .. "/Assets")
	if #files == 0 then
		return false, "[NvimUnity] No .cs files found in " .. self.rootFolder .. "/Assets..."
	end

	-- Criar novo bloco <Compile />
	-- Create new <Compile/> block
	local newCompileTags = {}
	for _, filename in ipairs(files) do
		local cutFile = utils.cutPath(utils.uriToPath(filename), "Assets")
		table.insert(newCompileTags, '    <Compile Include="' .. cutFile .. '" />')
	end
	local newBlock = table.concat(newCompileTags, "\n")
	-- Procurar placeholder
	-- Search for placeholder

	local placeholderPattern = "<!%-%- %{%{COMPILE_INCLUDES%}%} %-%->"
	local startPos, endPos = self.content[file]:find(placeholderPattern)

	if startPos and endPos then
		-- Placeholder existe, substituir apenas as <Compile /> após ele
		-- Placeholder exists, only replace the <Compile /> after it
		local before = self.content[file]:sub(1, endPos)
		local after = self.content[file]:sub(endPos + 1)

		-- Remove os <Compile ... /> somente até </ItemGroup>
		-- Removes <Compile ... /> the only up to </ItemGroup>
		local itemGroupClose = after:find("</ItemGroup>")
		if itemGroupClose then
			local blockBeforeClose = after:sub(1, itemGroupClose - 1)
			local blockAfterClose = after:sub(itemGroupClose)

			-- Limpa apenas os <Compile /> nesse intervalo
			-- Clears only the <Compile /> in this range
			blockBeforeClose = blockBeforeClose:gsub('[ \t]*<Compile%s+Include%s*=%s*"[^"]-"%s*/>%s*\n?', "")

			after = blockBeforeClose .. blockAfterClose
		end

		-- Garante que o "before" termina com quebra de linha
		-- Ensures that the "before" ends with a line break
		if not before:match("\n$") then
			before = before .. "\n"
		end

		self.content[file] = before .. newBlock .. after

		return true, "[NvimUnity] Compile tags updated using existing placeholder"
	end

	-- Se NÃO houver placeholder, seguir lógica original, mas inserir o placeholder também
	-- If there is NO placeholder, follow original logic, but insert the placeholder as well
	self.content[file] = self.content[file]:gsub("<Compile%s+Include%s*=%s*[\"'][^\"']-[\"']%s*/>%s*\n?", "")

	local openTag, innerContent, closeTag = self.content[file]:match("(<Project.-\n)(.-)(</Project>)")
	if not openTag then
		return false, "[NvimUnity] <Project> tag not found"
	end

	local lines = {}
	for line in innerContent:gmatch("([^\n]*)\n?") do
		table.insert(lines, line)
	end

	local depth = 0
	local childrenCount = 0
	local insertLine = #lines + 1 -- Começar no final das linhas, como fallback / Start at the end of lines, such as fallback

	-- Identificar a 10ª linha de inserção
	-- Identify the 10th insertion line
	for i, line in ipairs(lines) do
		local open = line:match("^%s*<([%w%.%-]+)[^>/]*>$")
		local selfClosing = line:match("^%s*<([%w%.%-]+)[^>]-/>%s*$")
		local close = line:match("^%s*</([%w%.%-]+)>%s*$")

		-- Considerar tags auto-fechadas ou abertas
		-- Consider auto-closed or open tags
		if selfClosing and depth == 0 then
			childrenCount = childrenCount + 1
		elseif open then
			if depth == 0 then
				childrenCount = childrenCount + 1
			end
			depth = depth + 1
		elseif close then
			depth = math.max(0, depth - 1)
		end

		-- Determina a linha de inserção após o 10º filho
		-- Determines the insertion line after the 10th child
		if childrenCount == 10 and depth == 0 then
			insertLine = i + 1
			break
		end
	end

	-- Monta bloco com placeholder + tags
	-- Assembles block with placeholder + tags
	local newBlockWithPlaceholderLines = {
		"  <ItemGroup>",
		"  <!-- Auto-generated block: do not modify manually or remove these commented lines -->",
		"  <!-- {{COMPILE_INCLUDES}} -->",
		newBlock,
		"  </ItemGroup>",
	}

	-- Inserir o novo bloco nas linhas no local adequado
	-- Insert the new block into the rows in the proper location
	for i = #newBlockWithPlaceholderLines, 1, -1 do
		table.insert(lines, insertLine, newBlockWithPlaceholderLines[i])
	end

	self.content[file] = openTag .. table.concat(lines, "\n") .. "\n" .. closeTag

	return true, "[NvimUnity] Compile tags inserted with new placeholder"
end

function XmlCsprojHandler:openUnity()
	local root = self.rootFolder
	local unity = config.unity_path

	-- Verificar se Unity já está rodando (simples, por processo)
	-- Check if Unity is already running (simple, per process)
	local is_running = vim.fn.system("tasklist"):find("Unity.exe")

	if is_running then
		print("⚠ Unity já está aberto.")
		return
	end

	if not unity or vim.fn.filereadable(unity) == 0 then
		vim.notify("[nvim-unity] Unity path is not set or invalid", vim.log.levels.ERROR)
		return
	end

	-- Checa se o projeto é Unity (tem pasta Assets)
	-- Check if the project is Unity (has Assets folder)
	if vim.fn.isdirectory(root .. "/Assets") == 0 then
		vim.notify("[nvim-unity] This folder is not a Unity project", vim.log.levels.WARN)
		return
	end

	-- Executa Unity com o path do projeto atual
	-- Runs Unity with the current project path
	vim.fn.jobstart({ unity, config.unity_path, root }, {
		detach = true,
	})

	vim.notify("[nvim-unity] Opening Unity project...", vim.log.levels.INFO)
end

return XmlCsprojHandler
