struct ParserError <: Exception
    msg::String
end

Base.showerror(io::IO, e::ParserError) = print(io, "ParserError: "*e.msg)

function get_operator(code::String)
    i = 1
    while i <= length(code)
        if code[i] == ' '
            return code[1:i-1]
        end
        i += 1
    end
    return code
end

# if nl is true
# newline is also counted
function chop_space(s::AbstractString, nl::Bool, tail::Bool)
    i = 0
    rs = (tail) ? reverse(s) : s
    
    if nl
        while i < length(s)
            if rs[i+1] == ' ' || rs[i+1] == '\n'
                i += 1
            else
                break
            end
        end
    else
        while i < length(s)
            if rs[i+1] == ' '
                i += 1
            else
                break
            end
        end
    end
    if tail
        return chop(s, tail=i)
    else
        return chop(s, head=i)
    end
end

function tokens2string(tokens::Vector{Token}, config::ParserConfig)
    txt = ""
    for token in tokens
        if isa(token, String)
            txt *= token
        elseif token == :plus
            txt *= '+'
        elseif token == :minus
            txt *= '-'
        elseif token == :control_start
            txt *= config.control_block[1]
        elseif token == :control_end
            txt *= config.control_block[2]
        elseif token == :expression_start
            txt *= config.expression_block[1]
        elseif token == :expression_end
            txt += config.expression_block[2]
        elseif token == :jl_start
            txt *= config.jl_block[1]
        elseif token == :jl_end
            txt +~ config.jl_block[2]
        elseif token == :comment_start
            txt *= config.comment_block[1]
        elseif token == :comment_end
            txt *= config.comment_block[2]
        end
    end
    return txt
end

function parse_meta(tokens::Vector{Token}, config::ParserConfig; parse_macro::Bool = false, include::Bool=false)
    super = nothing
    out_tokens = Token[""]
    macros = Dict{AbstractString, Vector{Token}}()
    macro_def = ""
    macro_content = Vector{Token}()
    comment = false
    raw = false
    raw_idx = [1, 1]
    next_trim = ' '
    i = 1
    while i <= length(tokens)
        # inside of raw block
        if raw
            if tokens[i] == :control_start
                raw_idx[2] = i-1
                i += 1
                lstrip_token = ' '
                # record lstrip token
                if tokens[i] == :plus
                    lstrip_token = '+'
                    i += 1
                elseif tokens[i] == :minus
                    lstrip_token = '-'
                    i += 1
                end
                !isa(tokens[i], String) && throw(ParserError("invalid control block: parser couldn't recognize the inside of control block"))

                code = string(strip(tokens[i]))
                if code == "endraw"
                    raw = false
                    push!(out_tokens, tokens2string(tokens[raw_idx[1]:raw_idx[2]], config))
                    i += 1
                else
                    i += 1
                    continue
                end

                # process lstrip token
                if lstrip_token == '-'
                    out_tokens[end] = chop_space(out_tokens[end], true, true)
                elseif lstrip_token == ' '
                    if config.lstrip_blocks
                        out_tokens[end] = chop_space(out_tokens[end], false, true)
                    end
                end

                # record trim token
                if tokens[i] == :plus
                    next_trim = '+'
                    i += 1
                elseif tokens[i] == :minus
                    next_trim = '-'
                    i += 1
                else
                    next_trim = ' '
                end
                !(tokens[i] == :control_end) && throw(Parser("invalid control block: control block without end token"))
                i += 1
                continue
            else
                i += 1
                continue
            end
        end

        # check end of comment block
        if tokens[i] == :comment_end
            if comment
                comment = false
                i += 1
                continue
            else
                throw(ParserError("invalid end token: end of comment block without start of comment block"))
            end
        end
        # inside of comment block
        if comment
            i += 1
            continue
        end

        # parse inside of macro block
        # this part is largely same to that of out of macro block
        # HACK: I should solve this duplication
        if macro_def != ""
            if tokens[i] == :control_start
                i += 1
                if tokens[i] == :plus
                    i += 1
                elseif tokens[i] == :minus
                    if isa(macro_content[end], String)
                        macro_content[end] = chop_space(macro_content[end], true, true)
                    end
                    i += 1
                else
                    if config.lstrip_blocks && isa(macro_content[end], AbstractString)
                        macro_content[end] = chop_space(macro_content[end], false, true)
                    end
                end
                # check format
                !isa(tokens[i], String) && throw(ParserError("invalid control block: parser couldn't recognize the inside of control block"))
                
                code = string(strip(tokens[i]))
                operator = get_operator(code)
                if operator == "raw"
                    raw = true
                elseif operator == "macro"
                    throw(ParserError("nesting macro block is not allowed"))
                elseif operator == "endmacro"
                    macros[macro_def] = macro_content
                    macro_def = ""
                    macro_content = Vector{Token}()
                elseif operator == "include"
                    file_name = strip(code[8:end])
                    if file_name[1] == file_name[end] == '\"'
                        open(config.dir*"/"*file_name[2:end-1], "r") do f
                            _, external_tokens, external_macros = parse_meta(read(f, String), filters, config, include=true)
                            !isempty(external_macros) && throw(ParserError("nesting macros is not allowed"))
                            append!(macro_content, external_tokens)
                        end
                    else
                        throw(ParserError("failed to include from $file_name: file name have to be enclosed in double quotation marks"))
                    end
                elseif operator == "extends"
                    throw(ParserError("invalid block: `extends` must be at the top of templates"))
                else
                    append!(macro_content, [:control_start, tokens[i], :control_end])
                end
    
                i += 1
                # process trim token
                if tokens[i] == :plus
                    next_trim = '+'
                    i += 1
                elseif tokens[i] == :minus
                    next_trim = '-'
                    i += 1
                else
                    next_trim = ' '
                end
                # check format
                !(tokens[i] == :control_end) && throw(Parser("invalid control block: control block without end token"))
    
                # record the index of start of the raw block
                if raw
                    raw_idx[1] = i + 1
                end
    
            # comment start
            elseif tokens[i] == :comment_start
                comment = true
    
            # push other(assumed to be string) tokens
            else
                if isa(tokens[i], String)
                    s = tokens[i]
                    if isempty(s)
                        i += 1
                        continue
                    end
                    if next_trim == ' '
                        if config.trim_blocks
                            if s[1] == '\n'
                                s = s[2:end]
                            end
                        end
                    elseif next_trim == '-'
                        s = chop_space(s, true, false)
                    end
                    next_trim = ' '
                    push!(macro_content, s)
                else
                    push!(macro_content, tokens[i])
                end
            end
            i += 1
            continue
        end

        # main control flow
        if tokens[i] == :control_start
            i += 1
            # process lstrip token
            if tokens[i] == :plus
                i += 1
            elseif tokens[i] == :minus
                if isa(out_tokens[end], AbstractString)
                    out_tokens[end] = chop_space(out_tokens[end], true, true)
                end
                i += 1
            else
                if config.lstrip_blocks && isa(out_tokens[end], AbstractString)
                    out_tokens[end] = chop_space(out_tokens[end], false, true)
                end
            end
            # check format
            !isa(tokens[i], String) && throw(ParserError("invalid control block: parser couldn't recognize the inside of control block"))
            
            code = string(strip(tokens[i]))
            operator = get_operator(code)
            if operator == "raw"
                raw = true
            elseif operator == "macro"
                macro_def = lstrip(code[6:end])
            elseif operator == "import"
                include && throw(ParserError("invalid block: `import` must be at the top of templates"))
                code_tokens = split(code[7:end])
                file_name = code_tokens[1]
                if code_tokens[3] != "as"
                    throw(ParserError("incorrect `import` block: your import block is broken. please look at the docs for detail."))
                end
                alias = code_tokens[4]
                if file_name[1] == file_name[end] == '\"'
                    open(config.dir*"/"*file_name[2:end-1], "r") do f
                        external_macros = parse_meta(read(f, String), filters, config, parse_macros=true)
                        for em in external_macros
                            macros[alias*"."*em[1]] = em[2]
                        end
                    end
                else
                    throw(ParserError("failed to import macro from $file_name: file name have to be enclosed in double quotation marks"))
                end
            elseif operator == "from"
                include && throw(ParserError("invalid block: `from` must be at the top of templates"))
                import_st = match(r"from\s*(?<file_name>.*?)\s*import(?<body>.*)", code)
                if isnothing(import_st)
                    throw(ParserError("incorrect `import` block: your import block is broken. please look at the docs for detail."))
                end
                file_name = import_st[:file_name]
                external_macros = Dict()
                open(config.dir*"/"*file_name[2:end-1], "r") do f
                    external_macros = parse_meta(read(f, String), filters, config, parse_macros=true)
                end
                for macro_name in split(import_st[:body], ",")
                    def_element = split(macro_name)
                    if length(def_element) == 1
                        if haskey(external_macros, def_element[1])
                            macros[def_element[1]] = external_macros[def_element[1]]
                        else
                            @warn "failed to impoer external macro named $(def_element[1])"
                        end
                    elseif length(def_element) == 3
                        if haskey(external_macros, def_element[1])
                            macros[def_element[3]] = external_macros[def_element[1]]
                        else
                            @warn "failed to import external macro named $(def_element[1])"
                        end
                    else
                        throw(ParserError("incorrect `import` block: your import block is broken. please look at the docs for detail."))
                    end
                end
            elseif operator == "include"
                file_name = strip(code[8:end])
                if file_name[1] == file_name[end] == '\"'
                    open(config.dir*"/"*file_name[2:end-1], "r") do f
                        _, external_tokens, external_macros = parse_meta(read(f, String), filters, config, include=true)
                        for em in external_macros
                            macros[alias*"."*em[1]] = em[2]
                        end
                        append!(out_tokens, external_tokens)
                    end
                else
                    throw(ParserError("failed to include from $file_name: file name have to be enclosed in double quotation marks"))
                end
            elseif operator == "extends"
                include && throw(ParserError("invalid block: `extends` must be at the top of templates"))
                super = Template()
            else
                append!(out_tokens, [:control_start, tokens[i], :control_end])
            end

            i += 1
            # process trim token
            if tokens[i] == :plus
                next_trim = '+'
                i += 1
            elseif tokens[i] == :minus
                next_trim = '-'
                i += 1
            else
                next_trim = ' '
            end
            # check format
            !(tokens[i] == :control_end) && throw(ParserError("invalid control block: control block without end token"))

            # record the index of start of the raw block
            if raw
                raw_idx[1] = i + 1
            end

        # comment start
        elseif tokens[i] == :comment_start
            comment = true

        # push other(assumed to be string) tokens
        else
            if isa(tokens[i], String)
                s = tokens[i]
                if isempty(s)
                    i += 1
                    continue
                end
                if next_trim == ' '
                    if config.trim_blocks
                        if s[1] == '\n'
                            s = s[2:end]
                        end
                    end
                elseif next_trim == '-'
                    s = chop_space(s, true, false)
                end
                next_trim = ' '
                push!(out_tokens, s)
            else
                push!(out_tokens, tokens[i])
            end
        end
        i += 1
    end
    if parse_macro
        return macros
    else
        return super, filter(x->x!="", out_tokens), macros
    end
end

function parse_template(txt::String, config::ParserConfig)
    # tokenize
    tokens = tokenizer(txt, config)
    # process meta information
    super, tokens, _ = parse_meta(tokens, config)

    # array to store blocks
    blocks = Vector{TmpBlock}
    # if position is in block this variable has non-zero value
    # this variable is also used to validate the depth of start and end position
    in_block_depth = 0
    # code block depth
    depth = 0
    
    # prepare the array to store the code blocks
    elements = CodeBlockVector(undef, 0)
    code_block = SubCodeBlockVector(undef, 0)
    
    i = 1
    code = ""
    while i <= length(tokens)
        if tokens[i] == :control_start
            i += 1
            code = strip(tokens[i])
            operator = get_operator(code)
            
            if operator == "endblock"
                if in_block_depth == 0
                    throw(ParserError("invalid end of block: `endblock` statement without `block` statement"))
                elseif in_block_depth != 1
                    throw(ParserError("invalid end of block: this block has the statement which is not closed"))
                end
                in_block_depth -= 1
                push!(blocks, code_block[end])
                if depth == 0
                    push!(elements, TmpCodeBlock(code_block))
                    code_block = SubCodeBlock(undef, 0)
                end
                
            elseif operator == "block"
                if in_block_depth != 0
                    throw(ParserError("invalid block: nested block is invalid"))
                end
                in_block_depth += 1
                push!(code_block, TmpBlock(contents[2], Vector()))
                
            elseif operator == "set"
                if in_block_depth != 0
                    push!(code_block[end], TmpStatement(code))
                elseif depth == 0
                    push!(elements, TmpCodeBlock([TmpStatement(code[4:end])]))
                else
                    push!(code_block, TmpStatement(code))
                end

            elseif operator == "end"
                if depth == 0 && in_block_depth == 0
                    throw(ParserError("`end` is found at block depth 0"))
                elseif in_block_depth != 0
                    in_block_depth -= 1
                    in_block_depth == 0 && throw(ParserError("invalid `end` is found: this `end` should be `endblock`"))
                    push!(code_block[end], TmpStatement("end"))
                else
                    depth -= 1
                    push!(code_block, TmpStatement("end"))
                    if depth == 0
                        push!(elements, TmpCodeBlock(code_block))
                        code_block = SubCodeBlockVector(undef, 0)
                    end
                end

            else
                if !(operator in ["for", "if", "elseif", "else", "let"])
                    throw(ParserError("this block is invalid: $code"))
                end
                if in_block_depth != 0
                    if operator in ["for", "if", "let"]
                        in_block_depth += 1
                    end
                    push!(code_block[end], TmpStatement(code))
                else
                    if operator in ["for", "if", "let"]
                        depth += 1
                    end
                    push!(code_block, TmpStatement(code))
                end
            end
            
            tokens[i+1] != :control_end && throw(ParserError("invalid control block: this block is not closed"))
            i += 1
            
        elseif tokens[i] == :expression_start
            i += 1
            code = strip(tokens[i])

            exp = (occursin(r".*?\(.*?\)", code)) ? SuperBlock(length(split(code, "."))) : VariableBlock(code)
            if in_block_depth != 0
                push!(code_block[end], exp)
            elseif depth == 0
                push!(elements, exp)
            else
                push!(code_block, exp)
            end
            tokens[i+1] != :expression_end && throw(ParserError("invalid expression block: this block is not closed"))
            i += 1
            
        elseif tokens[i] == :jl_start
            i += 1
            code = tokens[i]
            if in_block_depth != 0
                push!(code_block[end], JLCodeBlock(code))
            elseif depth == 0
                push!(elements, JLCodeBlock(code))
            else
                push!(code_block, JLCodeBlock(code))
            end
            tokens[i+1] != :jl_end && throw(ParserError("invalid jl block: this block is not closed"))
            i += 1
            
        elseif isa(tokens[i], AbstractString)
            if in_block_depth != 0
                push!(code_block[end], tokens[i])
            elseif depth == 0
                push!(elements, tokens[i])
            else
                push!(code_block, tokens[i])
            end
        else
            throw(ParserError("unexpexted token: $(tokens[i]) is unexpected. maybe the parser is broken."))
        end
        i += 1
    end
    return super, elements, blocks
end