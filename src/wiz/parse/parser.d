module wiz.parse.parser;

static import std.conv;
static import std.path;
static import std.array;
static import std.stdio;
static import std.string;
static import std.algorithm;

import wiz.lib;
import wiz.parse.lib;

class Parser
{
    private Scanner scanner;
    private Scanner[] includes;
    private bool[string] included;
    private Token token;
    private string text;
    private Keyword keyword;

    this(Scanner scanner)
    {
        this.scanner = scanner;
    }
    
    void nextToken()
    {
        token = scanner.next();
        text = scanner.getLastText();
        keyword = Keyword.None;
        if(token == Token.Identifier)
        {
            keyword = findKeyword(text);
        }
    }
    
    void reject(string expectation = null, bool advance = true)
    {
        reject(token, text, expectation, advance);
    }

    void reject(Token token, string text, string expectation = null, bool advance = true)
    {
        if(expectation is null)
        {
            error("unexpected " ~ getVerboseTokenName(token, text), scanner.getLocation());
        }
        else
        {
            error("expected " ~ expectation ~ ", but got " ~ getVerboseTokenName(token, text) ~ " instead", scanner.getLocation());
        }
        if(advance)
        {
            nextToken();
        }
    }

    bool consume(Token expected)
    {
        if(token == expected)
        {
            nextToken();
            return true;
        }
        else
        {
            reject(getSimpleTokenName(expected));
            return false;
        }     
    }
    
    bool checkIdentifier(bool allowKeywords = false)
    {
        if(token == Token.Identifier && (!allowKeywords && keyword == Keyword.None || allowKeywords))
        {
            return true; 
        }
        else
        {
            error("expected identifier but got " ~ getVerboseTokenName(token, text) ~ " instead", scanner.getLocation());
            return false;
        }
    }
    
    bool checkIdentifier(Keyword[] permissibleKeywords)
    {
        checkIdentifier(true);
        
        if(keyword == Keyword.None || std.algorithm.find(permissibleKeywords, keyword).length > 0)
        {
            return true;
        }
        else
        {
            string[] keywordNames = [];
            foreach(keyword; permissibleKeywords)
            {
                keywordNames ~= "keyword '" ~ getKeywordName(keyword) ~ "'";
            }
            keywordNames[keywordNames.length - 1] = "or " ~ keywordNames[keywordNames.length - 1];
            
            error("expected identifier, " ~ std.array.join(keywordNames, ", ") ~ ", but got " ~ getVerboseTokenName(token, text) ~ " instead", scanner.getLocation());
            return false;
        }
    }
    
    auto parse()
    {
        nextToken();
        auto program = parseProgram();
        compile.verify();
        return program;
    }
    
    auto parseProgram()
    {
        // program = (include | statement)* EOF
        auto location = scanner.getLocation();
        ast.Statement[] statements;
        while(true)
        {
            if(token == Token.EndOfFile)
            {
                if(includes.length == 0)
                {
                    break;
                }
                else
                {
                    // Remove include guard.
                    included.remove(scanner.getLocation().file);
                    // Pop previous scanner off stack.
                    auto old = scanner;
                    scanner = std.array.back(includes);
                    std.array.popBack(includes);
                    // Ready a new token for the scanner.
                    nextToken();
                }
            }
            if(keyword == Keyword.End || keyword == Keyword.Else || keyword == Keyword.ElseIf)
            {
                reject();
            }
            if(keyword == Keyword.Include)
            {
                parseInclude();
            }
            if(auto statement = parseStatement())
            {
                statements ~= statement;
            }
        }
        return new ast.Block(statements, location);
    }
    
    ast.Statement[] parseCompound()
    {
        // compound = statement* 'end'
        ast.Statement[] statements;
        while(true)
        {
            if(token == Token.EndOfFile)
            {
                reject("'end'");
                return null;
            }
            if(keyword == Keyword.End)
            {
                return statements;
            }
            if(keyword == Keyword.Else || keyword == Keyword.ElseIf || keyword == Keyword.Include)
            {
                reject("'end'");
            }
            if(auto statement = parseStatement())
            {
                statements ~= statement;
            }
        }
    }
    
    ast.Statement[] parseConditionalCompound()
    {
        // conditional_compound = statement* ('else' | 'elseif' | 'end')
        ast.Statement[] statements;
        while(true)
        {
            if(token == Token.EndOfFile)
            {
                reject("'end'");
            }
            if(keyword == Keyword.End || keyword == Keyword.Else || keyword == Keyword.ElseIf)
            {
                return statements;
            }
            if(keyword == Keyword.Include)
            {
                reject("'end'");
            }
            if(auto statement = parseStatement())
            {
                statements ~= statement;
            }
        }
    }

    ast.Statement parseStatement()
    {
        // statement =
        //      embed
        //      | relocation
        //      | block
        //      | bank
        //      | label
        //      | constant
        //      | enumeration
        //      | variable
        //      | data
        //      | jump
        //      | conditional
        //      | loop
        //      | comparison
        //      | command
        //      | assignment
        switch(token)
        {
            case Token.Identifier:
                switch(keyword)
                {
                    case Keyword.Embed:
                        return parseEmbed();
                    case Keyword.In:
                        return parseRelocation();
                    case Keyword.Do, Keyword.Package:
                        return parseBlock();
                    case Keyword.Bank:
                        return parseBankDecl();
                    case Keyword.Def:
                        return parseLabelDecl();
                    case Keyword.Let:
                        return parseConstDecl();
                    case Keyword.Enum:
                        return parseEnumDecl();
                    case Keyword.Var:
                        return parseVarDecl();
                    case Keyword.Byte, Keyword.Word:
                        return parseData();
                    case Keyword.Goto, Keyword.Call,
                        Keyword.Return, Keyword.Resume,
                        Keyword.Break, Keyword.Continue,
                        Keyword.While, Keyword.Until,
                        Keyword.Abort, Keyword.Sleep, Keyword.Suspend, Keyword.Nop:
                        return parseJump();
                    case Keyword.If:
                        return parseConditional();
                    case Keyword.Repeat:
                        return parseLoop();
                    case Keyword.Compare:
                        return parseComparison();
                    case Keyword.Bit:
                    case Keyword.Push:
                        return parseCommand();
                    case Keyword.None:
                        // Some unreserved identifier. Try and parse as a term in an assignment!
                        return parseAssignment();
                    default:
                        reject("statement");
                        break;
                }
                break;
            case Token.Integer, Token.Hexadecimal, Token.Binary, Token.String, Token.LParen:
                reject("statement", false);
                skipAssignment(true);
                break;
            case Token.Set:
                reject("statement", false);
                skipAssignment(false);
                break;
            case Token.LBracket:
                return parseAssignment();
                break;
            case Token.Semi:
                // semi-colon, skip.
                nextToken();
                break;
            default:
                reject("statement");
                break;
        }
        return null;
    }
        
    void parseInclude()
    {
        // include = 'include' STRING
        nextToken(); // IDENTIFIER (keyword 'include')
        
        string filename = null;
        if(token == Token.String)
        {
            // Don't call nextToken() here, we'll be doing that when the scanner's popped off later.
            filename = text;
        }
        else
        {
            consume(Token.String);
            return;
        }
        
        // Make the filename relative to its current source.
        filename = std.path.dirName(scanner.getLocation().file) ~ std.path.dirSeparator ~ filename;

        // Make sure the start path is included in the list of included filenames.
        if(included.length == 0)
        {
            string cur = scanner.getLocation().file;
            included[std.path.dirName(cur) ~ std.path.dirSeparator ~ cur] = true;
        }
        // Already included. Skip!
        if(included.get(filename, false))
        {
            nextToken(); // STRING
            return;
        }
        
        // Push old scanner onto stack.
        includes ~= scanner;
        // Add include guard.
        included[filename] = true;
        
        // Open the new file.
        std.stdio.File file;
        try
        {
            file = std.stdio.File(filename, "rb");
        }
        catch(Exception e)
        {
            // If file fails to open, then file will be not be open. Ignore exceptions.
        }
        if(file.isOpen())
        {
            // Swap scanner.
            scanner = new Scanner(file, filename);
        }
        else
        {
            error("could not include file '" ~ filename ~ "'", scanner.getLocation(), true);
        }
        // Now, ready the first token of the file.
        nextToken();
    }
    
    auto parseEmbed()
    {
        // embed = 'embed' STRING
        auto location = scanner.getLocation();
        nextToken(); // IDENTIFIER (keyword 'embed')
        
        if(token == Token.String)
        {
            string filename = text;
            nextToken(); // STRING
            
            // Make the filename relative to its current source.
            filename = std.path.dirName(scanner.getLocation().file) ~ std.path.dirSeparator ~ filename;   
            return new ast.Embed(filename, location);
        }
        else
        {
            consume(Token.String);
            return null;
        }
    }
    
    auto parseRelocation()
    {
        // relocation = 'in' IDENTIFIER (',' expression)? ':'
        auto location = scanner.getLocation();
        string name;
        ast.Expression dest;
        
        nextToken(); // IDENTIFIER (keyword 'in')
        if(checkIdentifier())
        {
            name = text;
        }
        nextToken(); // IDENTIFIER
        // (, expr)?
        if(token == Token.Comma)
        {
            nextToken(); // ,
            dest = parseExpression(); // expression
        }
        consume(Token.Colon); // :
        
        return new ast.Relocation(name, dest, location);
    }
    
    auto parseBlock()
    {
        // block = ('package' IDENTIFIER | 'do') statement* 'end'
        auto location = scanner.getLocation();
        switch(keyword)
        {
            case Keyword.Do:
                nextToken(); // IDENTIFIER (keyword 'do')
                auto statements = parseCompound(); // compound statement
                nextToken(); // IDENTIFIER (keyword 'end')
                return new ast.Block(statements, location);
            case Keyword.Package:
                string name;
                
                nextToken(); // IDENTIFIER (keyword 'package')
                if(checkIdentifier())
                {
                    name = text;
                }
                nextToken(); // IDENTIFIER
                auto statements = parseCompound(); // compound statement
                nextToken(); // IDENTIFIER (keyword 'end')
                return new ast.Block(name, statements, location);
            default:
                error("unexpected compilation error: incorrectly classified token as start of block statement", scanner.getLocation());
                assert(false);
        }
    }
    
    auto parseBankDecl()
    {
        // bank = 'bank' IDENTIFIER (',' IDENTIFIER)* ':' IDENTIFIER '*' expression
        auto location = scanner.getLocation();
        
        string[] names;
        string type;
        ast.Expression size;
        
        nextToken(); // IDENTIFIER (keyword 'bank')
        
        if(checkIdentifier())
        {
            names ~= text;
        }
        nextToken(); // IDENTIFIER
        
        // Check if we should match (',' id)*
        while(token == Token.Comma)
        {
            nextToken(); // ,
            if(token == Token.Identifier)
            {
                if(checkIdentifier())
                {
                    // parse name
                    names ~= text;
                }
                nextToken(); // IDENTIFIER
            }
            else
            {
                reject("identifier after ',' in bank Defaration");
                break;
            }
        }
        
        consume(Token.Colon); // :
        
        if(checkIdentifier())
        {
            type = text;
        }
        nextToken(); // IDENTIFIER (bank type)
        consume(Token.Mul); // *
        size = parseExpression(); // term
        
        return new ast.BankDecl(names, type, size, location);
    }
    
    auto parseLabelDecl()
    {
        // label = 'def' IDENTIFIER ':'
        auto location = scanner.getLocation();
        
        string name;
        
        nextToken(); // IDENTIFIER (keyword 'def')
        if(checkIdentifier())
        {
            name = text;
        }
        nextToken(); // IDENTIFIER
        consume(Token.Colon);
        
        return new ast.LabelDecl(name, location);
    }

    auto parseStorage()
    {
        // storage = ('byte' | 'word') ('*' expression)?
        auto location = scanner.getLocation();
        if(checkIdentifier(true))
        {
            Keyword storageType;
            switch(keyword)
            {
                case Keyword.Byte:
                case Keyword.Word:
                    storageType = keyword;
                    break;
                default:
                    error("invalid type specifier '" ~ text ~ "'. only 'byte' and 'word' are allowed.", scanner.getLocation());
            }
            nextToken(); // IDENTIFIER (keyword 'byte'/'word')
            // ('*' array_size)?
            ast.Expression arraySize;
            if(token == Token.Mul)
            {
                nextToken(); // *
                arraySize = parseExpression(); // expression
            } 
            return new ast.Storage(storageType, arraySize, location);
        }
        else
        {
            reject("type specifier");
            return null;
        }
    }
    
    auto parseConstDecl()
    {
        // constant = 'let' IDENTIFIER '=' expression
        auto location = scanner.getLocation();
        
        string name;
        ast.Storage storage;
        ast.Expression value;
        
        nextToken(); // IDENTIFIER (keyword 'let')
        if(checkIdentifier())
        {
            name = text;
        }
        nextToken(); // IDENTIFIER
        consume(Token.Set); // =
        value = parseExpression(); // expression
        return new ast.ConstDecl(name, value, location);
    }
    
    auto parseEnumDecl()
    {
        // enumeration = 'enum' ':' enum_item (',' enum_item)*
        //      where enum_item = IDENTIFIER ('=' expression)?
        auto enumLocation = scanner.getLocation();
        auto constantLocation = enumLocation;
        string name;
        ast.Expression value;
        uint offset;
        ast.ConstDecl[] constants;
        
        nextToken(); // IDENTIFIER (keyword 'enum')
        consume(Token.Colon); // :
        
        if(checkIdentifier())
        {
            name = text;
        }
        constantLocation = scanner.getLocation();
        nextToken(); // IDENTIFIER
        // ('=' expr)?
        if(token == Token.Set)
        {
            consume(Token.Set); // =
            value = parseExpression();
        }
        else
        {
            value = new ast.Number(Token.Integer, 0, constantLocation);
        }

        constants ~= new ast.ConstDecl(name, value, offset, constantLocation);
        offset++;
        
        // (',' name ('=' expr)?)*
        while(token == Token.Comma)
        {
            nextToken(); // ,
            if(token == Token.Identifier)
            {
                if(checkIdentifier())
                {
                    name = text;
                }
                constantLocation = scanner.getLocation();
                nextToken(); // IDENTIFIER
                // ('=' expr)?
                if(token == Token.Set)
                {
                    consume(Token.Set); // =
                    value = parseExpression();
                    offset = 0; // If we explicitly set a value, then we reset the enum expression offset.
                }
                
                constants ~= new ast.ConstDecl(name, value, offset, constantLocation);
                offset++;
            }
            else
            {
                reject("identifier after ',' in enum Defaration");
                break;
            }
        }
        
        return new ast.EnumDecl(constants, enumLocation);
    }
    
    auto parseVarDecl()
    {
        // variable = 'var' IDENTIFIER (',' IDENTIFIER)*
        //      ':' ('byte' | 'word') '*' expression
        auto location = scanner.getLocation();
        
        string[] names;
        nextToken(); // IDENTIFIER (keyword 'var')
        
        if(checkIdentifier())
        {
            names ~= text;
        }
        nextToken(); // IDENTIFIER
        
        // Check if we should match (',' id)*
        while(token == Token.Comma)
        {
            nextToken(); // ,
            if(token == Token.Identifier)
            {
                if(checkIdentifier())
                {
                    // parse name
                    names ~= text;
                }
                nextToken(); // IDENTIFIER
            }
            else
            {
                reject("identifier after ',' in variable Defaration");
                break;
            }
        }
        
        consume(Token.Colon); // :
        auto storage = parseStorage();
        return new ast.VarDecl(names, storage, location);
    }
    
    auto parseData()
    {
        // data = ('byte' | 'word') data_item (',' data_item)*
        //      where data_item = expression | STRING
        auto location = scanner.getLocation();
        auto storage = parseStorage();
        consume(Token.Colon); // :
        
        ast.DataItem[] items;

        // item (',' item)*
        while(true)
        {
            ast.Expression expr = parseExpression(); // expression
            items ~= new ast.DataItem(expr, expr.location);
            // (',' item)*
            if(token == Token.Comma)
            {
                nextToken(); // ,
                continue;
            }
            break;
        }
        return new ast.Data(storage, items, location);
    }
    
    auto parseJump()
    {
        // jump = 'goto' expression ('when' jump_condition)?
        //      | 'call' expression ('when' jump_condition)?
        //      | 'return' ('when' jump_condition)?
        //      | 'resume' ('when' jump_condition)?
        //      | 'break' ('when' jump_condition)?
        //      | 'continue' ('when' jump_condition)?
        //      | 'while' jump_condition
        //      | 'until' jump_condition
        //      | 'abort'
        //      | 'sleep'
        //      | 'suspend'
        //      | 'nop'
        auto location = scanner.getLocation();

        auto type = keyword;
        nextToken(); // IDENTIFIER (keyword)
        switch(type)
        {
            case Keyword.Goto, Keyword.Call:
                auto destination = parseExpression();
                ast.JumpCondition condition = null;
                if(token == Token.Identifier && keyword == Keyword.When)
                {
                    nextToken(); // IDENTIFIER (keyword 'when')
                    condition = parseJumpCondition("'when'");
                }
                return new ast.Jump(type, destination, condition, location);
                break;
            case Keyword.Return, Keyword.Resume, Keyword.Break, Keyword.Continue:
                ast.JumpCondition condition = null;
                if(token == Token.Identifier && keyword == Keyword.When)
                {
                    nextToken(); // IDENTIFIER (keyword 'when')
                    condition = parseJumpCondition("'when'");
                }
                return new ast.Jump(type, condition, location);
            case Keyword.While:
                return new ast.Jump(type, parseJumpCondition("'while'"), location);
            case Keyword.Until:
                return new ast.Jump(type, parseJumpCondition("'until'"), location);
            default:
                return new ast.Jump(type, location);
        }
    }
    
    auto parseJumpCondition(string context)
    {
        // jump_condition = 'not'* (IDENTIFIER | '!=' | '==' | '<' | '>' | '<=' | '>=')
        ast.JumpCondition condition = null;
        
        // 'not'* (not isn't a keyword, but it has special meaning)
        bool negated = false;
        while(keyword == Keyword.Not)
        {
            nextToken(); // IDENTIFIER (keyword 'not')
            negated = !negated;
            context = "'not'";
        }
        
        switch(token)
        {
            case Token.Identifier:
                auto attr = parseAttribute();
                return new ast.JumpCondition(negated, attr, scanner.getLocation());
            case Token.NotEqual:
            case Token.Equal:
            case Token.Less:
            case Token.Greater:
            case Token.LessEqual:
            case Token.GreaterEqual:
                auto type = cast(Branch) token;
                nextToken(); // operator token
                return new ast.JumpCondition(negated, type, scanner.getLocation());
            default:
                reject("condition after " ~ context);
                return null;
        }        
    }
    
    auto parseConditional()
    {
        // condition = 'if' condition 'then' statement*
        //      ('elseif' condition 'then' statement*)*
        //      ('else' statement)? 'end'
        ast.Conditional first = null;
        ast.Conditional statement = null;
        
        // 'if' condition 'then' statement* ('elseif' condition 'then' statement*)*
        do
        {
            auto location = scanner.getLocation();
            nextToken(); // IDENTIFIER (keyword 'if' / 'elseif')
            
            auto condition = parseJumpCondition("'if'");
            
            if(keyword == Keyword.Then)
            {
                nextToken(); // IDENTIFIER (keyword 'then')
            }
            else
            {
                reject("'then'");
            }
            
            // statement*
            auto block = new ast.Block(parseConditionalCompound(), location);
            
            // Construct if statement, which is either static or runtime depending on argument before 'then'.
            auto previous = statement;
            statement = new ast.Conditional(condition, block, location);

            // If this is an 'elseif', join to previous 'if'/'elseif'.
            if(previous)
            {
                previous.alternative = statement;
            }
            else if(first is null)
            {
                first = statement;
            }
        } while(keyword == Keyword.ElseIf);
        
        // ('else' statement*)? 'end' (with error recovery for an invalid trailing else/elseif placement)
        if(keyword == Keyword.Else)
        {
            auto location = scanner.getLocation();
            nextToken(); // IDENTIFIER (keyword 'else')
            statement.alternative = new ast.Block(parseConditionalCompound(), location); // statement*
        }
        switch(keyword)
        {
            case Keyword.Else:
                error("duplicate 'else' clause found.", scanner.getLocation());
                break;
            case Keyword.ElseIf:
                // Seeing as we loop on elseif before an else/end, this must be an illegal use of elseif.
                error("'elseif' can't appear after 'else' clause.", scanner.getLocation());
                break;
            default:
        }

        if(keyword == Keyword.End)
        {
            nextToken(); // IDENTIFIER (keyword 'end')
        }
        else
        {
            reject("'end'");
        }
        return first;
    }
    
    auto parseLoop()
    {
        // loop = 'repeat' statement* 'end'
        auto location = scanner.getLocation();
        nextToken(); // IDENTIFIER (keyword 'repeat')
        auto block = new ast.Block(parseCompound(), location); // statement*
        nextToken(); // IDENTIFIER (keyword 'end')
        return new ast.Loop(block, location);
    }

    auto parseComparison()
    {
        // comparison = 'compare' expression ('to' expression)?
        auto location = scanner.getLocation();
        nextToken(); // IDENTIFIER (keyword 'compare')
        auto term = parseAssignableTerm();
        if(keyword == Keyword.To)
        {
            nextToken(); // IDENTIFIER (keyword 'to')
            ast.Expression other = parseExpression();
            return new ast.Comparison(term, other, location);
        }
        else
        {
            return new ast.Comparison(term, location);
        }
    }

    auto parseCommand()
    {
        // command = command_token expression
        auto location = scanner.getLocation();
        auto command = keyword;
        nextToken(); // IDENTIFIER (keyword)
        auto argument = parseExpression();
        return new ast.Command(command, argument, location);
    }

    void skipAssignment(bool leadingExpression)
    {
        // Some janky error recovery. Gobble an expression.
        if(leadingExpression)
        {
            parseExpression(); // expr
        }
        // If the expression is followed by an assignment, then gobble the assignment.
        if(token == Token.Set)
        {
            nextToken(); // =
            // If the thing after the = is an expression, then gobble that too.
            switch(token)
            {
                case Token.Integer, Token.Hexadecimal, Token.Binary, Token.String, Token.LParen:
                    parseExpression();
                    break;
                case Token.Identifier:
                    if(keyword == Keyword.None || keyword == Keyword.Pop)
                    {
                        parseExpression();
                    }
                    break;
                default:
            }
        }
    }

    auto parseAssignment()
    {
        // assignment = assignable_term ('=' expression ('via' term)? | postfix_token)
        auto location = scanner.getLocation();
        auto op = token;
        auto opText = text;
        auto dest = parseAssignableTerm(); // term
        if(token == Token.Set)
        {
            nextToken(); // =
            auto src = parseExpression(); // expression
            if(token == Token.Identifier && keyword == Keyword.Via)
            {
                nextToken(); // IDENTIFIER (keyword 'via')
                auto intermediary = parseTerm(); // term
                return new ast.Assignment(dest, intermediary, src, location);
            }
            else
            {
                return new ast.Assignment(dest, src, location);
            }
        }
        else if(isPostfixToken())
        {
            nextToken(); // postfix_token
            return new ast.Assignment(dest, cast(Postfix) op, location);
        }
        else
        {
            if(token == Token.Identifier || token == Token.Integer || token == Token.Hexadecimal || token == Token.Binary)
            {
                reject(op, opText, "statement", false);
            }
            else
            {
                reject("an assignment operator like '=', '++', '--' or '<>'");
            }
            skipAssignment(true);
            return null;
        }
    }

    auto parseExpression()
    {
        // expression = infix
        return parseInfix();
    }

    bool isInfixToken()
    {
        // infix_token = ...
        switch(token)
        {
            case Token.At:
            case Token.Add:
            case Token.Sub:
            case Token.Mul:
            case Token.Div:
            case Token.Mod:
            case Token.AddC:
            case Token.SubC:
            case Token.ShiftL:
            case Token.ShiftR:
            case Token.ArithShiftL:
            case Token.ArithShiftR:
            case Token.RotateL:
            case Token.RotateR:
            case Token.RotateLC:
            case Token.RotateRC:
            case Token.Or:
            case Token.And:
            case Token.Xor:
                return true;
            default:
                return false;
        }
    }

    bool isPrefixToken()
    {
        // prefix_token = ...
        switch(token)
        {
            case Token.Less:
            case Token.Greater:
            case Token.Swap:
            case Token.Sub:
                return true;
            default:
                return false;
        }
    }

    bool isPostfixToken()
    {
        // postfix_token = ...
        switch(token)
        {
            case Token.Inc:
            case Token.Dec:
                return true;
            default:
                return false;
        }
    }

    ast.Expression parseInfix()
    {
        // infix = postfix (infix_token postfix)*
        ast.Expression left = parsePrefix(); // postfix
        while(true)
        {
            auto location = scanner.getLocation();
            if(isInfixToken())
            {
                auto type = cast(Infix) token;
                nextToken(); // operator token
                auto right = parsePrefix(); // postfix
                left = new ast.Infix(type, left, right, location);
            }
            else
            {
                return left;
            }
        }
    }

    ast.Expression parsePrefix()
    {
        // prefix = prefix_token prefix | postfix
        if(isPrefixToken())
        {
            auto location = scanner.getLocation();
            auto op = cast(Prefix) token;
            nextToken(); // operator token
            auto expr = parsePrefix(); // prefix
            return new ast.Prefix(op, expr, location);
        }
        else
        {
            return parsePostfix(); // postfix
        }
    }

    ast.Expression parsePostfix()
    {
        // postfix = term postfix_token*
        auto expr = parseTerm(); // term
        while(true)
        {
            if(isPostfixToken())
            {
                auto op = cast(Postfix) token;
                expr = new ast.Postfix(op, expr, scanner.getLocation());
                nextToken(); // operator token
            }
            else
            {
                return expr;
            }
        }
    }

    ast.Expression parseAssignableTerm()
    {
        // assignable_term = term ('@' term)?
        auto location = scanner.getLocation();
        auto expr = parseTerm();
        if(token == Token.At)
        {
            nextToken(); // '@'
            return new ast.Infix(Infix.At, expr, parseTerm(), location);
        }
        else
        {
            return expr;
        }
    }

    ast.Expression parseTerm()
    {
        // term = INTEGER
        //      | HEXADECIMAL
        //      | LPAREN expression RPAREN
        //      | LBRACKET expression RBRACKET
        //      | IDENTIFIER ('.' IDENTIFIER)*
        //      | 'pop'
        auto location = scanner.getLocation();
        switch(token)
        {
            case Token.Integer:
                return parseNumber(10);
            case Token.Hexadecimal:
                return parseNumber(16);
            case Token.Binary:
                return parseNumber(2);
            case Token.String:
                ast.Expression expr = new ast.String(text, location);
                nextToken(); // STRING
                return expr;
            case Token.LParen:
                nextToken(); // (
                ast.Expression expr = parseExpression(); // expression 
                consume(Token.RParen); // )
                return new ast.Prefix(Prefix.Grouping, expr, location);
            case Token.LBracket:
                nextToken(); // [
                ast.Expression expr = parseExpression(); // expression
                
                if(token == Token.Colon)
                {
                    nextToken(); // :
                    ast.Expression index = parseExpression(); // expression
                    expr = new ast.Infix(Infix.Colon, expr, index, location);
                }
                consume(Token.RBracket); // ]
                return new ast.Prefix(Prefix.Indirection, expr, location);
            case Token.Identifier:
                if(keyword == Keyword.Pop)
                {
                    nextToken(); // IDENTIFIER
                    return new ast.Pop(location);
                }
                return parseAttribute();
            default:
                reject("expression");
                return null;
        }
    }

    auto parseNumber(uint radix)
    {
        // number = INTEGER | HEXADECIMAL | BINARY
        auto location = scanner.getLocation();
        auto numberToken = token;
        auto numberText = text;
        nextToken(); // number

        uint value;
        try
        {
            auto t = numberText;
            // prefix?
            if(radix != 10)
            {
                t = t[2..t.length];
                // A prefix with no number following isn't valid.
                if(t.length == 0)
                {
                    error(getVerboseTokenName(numberToken, numberText) ~ " is not a valid integer literal", location);
                    return null;
                }
            }
            value = std.conv.to!uint(t, radix);
        }
        catch(std.conv.ConvOverflowException e)
        {
            value = 0x10000;
        }
        if(value > 0xFFFF)
        {
            error(getVerboseTokenName(numberToken, numberText) ~ " is outside of permitted range 0..65535.", location);
            return null;
        }
        return new ast.Number(numberToken, value, location);
    }

    auto parseAttribute()
    {
        auto location = scanner.getLocation();
        string[] pieces;
        if(checkIdentifier())
        {
            pieces ~= text;
        }
        nextToken(); // IDENTIFIER
        
        // Check if we should match ('.' IDENTIFIER)*
        while(token == Token.Dot)
        {
            nextToken(); // .
            if(token == Token.Identifier)
            {
                if(checkIdentifier())
                {
                    pieces ~= text;
                }
                nextToken(); // IDENTIFIER
            }
            else
            {
                reject("identifier after '.' in term");
                break;
            }
        }

        return new ast.Attribute(pieces, location);
    }
}
