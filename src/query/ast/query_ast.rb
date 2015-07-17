require 'query/ast/term'
require 'query/ast/ast_walker'
require 'query/nick_expr'
require 'query/text_template'
require 'query/query_template_properties'
require 'command_context'

require 'sql/query_tables'
require 'sql/column_resolver'
require 'sql/join_resolver'
require 'sql/query_ast_sql'

module Query
  module AST
    ##
    # Represents an entire !lg/!lm query or subquery fragment.
    class QueryAST < Term
      ##
      # The query context.
      #
      # A query context is an object that represents a SQL table: logrecord for
      # !lg, and milestone for !lm. A context defines the fields that are
      # recognised (viz. the table columns), and may optionally refer to an
      # auto-join context, where referring to a field in the auto-joined context
      # implies automatically joining to that table.
      attr_reader :context

      ##
      # The query context name, possibly nil.
      attr_accessor :context_name

      ##
      # The head of the query for !lg queries "!lg HEAD / TAIL". The head is
      # always non-nil (but it may be empty for queries like "!lg").
      attr_accessor :head

      ##
      # The optional tail of the query for !lg ratio queries of the form
      # "!lg HEAD / TAIL". The tail is nil for non-ratio queries.
      attr_accessor :tail

      ##
      # The in-memory filter clause ("?: FILTER")
      attr_accessor :filter

      ##
      # The extra-field clause ("x=foo,bar"); may be nil.
      attr_accessor :extra

      ##
      # The summarise clause ("s=foo,bar"); may be nil.
      attr_accessor :summarise

      ##
      # The options clause ("-tv", "-log") etc.
      attr_accessor :options

      ##
      # The min|max clause.
      attr_accessor :sorts

      ##
      # The alias for this query when used in a larger query.
      attr_writer :alias

      ##
      # The requested game number.
      attr_accessor :game_number

      attr_accessor :nick, :default_nick

      ##
      # The query game type: crawl, sprint, zotdef, etc.
      attr_accessor :game

      attr_accessor :group_order, :keys
      attr_reader   :subquery_alias

      attr_writer :subquery_expression
      attr_writer :table_subquery

      ##
      # The list of subqueries or tables acting as joins on the primary.
      # In certain cases where all the body expressions refer purely
      # to fields in the join tables, the QueryAST may be degenerate.
      attr_reader :join_tables

      ##
      # A list of Query::AST::Expr objects joining this query or any of
      # its join_tables to any other QueryAST.
      attr_reader :join_conditions

      ##
      # An instance of Sql::QueryTables specifying the set of tables that must
      # be queried for this AST. Note that Sql::QueryTables may contain both
      # instances of Sql::QueryTable and anonymous nested QueryAST objects.
      attr_reader :query_tables

      def initialize(context_name, head, tail, filter)
        @game = GameContext.game
        @context = Sql::QueryContext.named(context_name.to_s)
        @head = head || Expr.and()
        @original_head = @head.dup
        @tail = tail
        @original_tail = @tail && @tail.dup
        @subquery_alias = nil
        @join_tables = []
        @join_conditions = []

        @filter = filter
        @options = []
        @opt_map = { }
        @sorts = []
        @keys = Query::AST::KeyedOptionList.new

        @nick = ASTWalker.find(@head) { |node|
          node.nick.value if node.is_a?(NickExpr)
        }

        @keyword_nick = ASTWalker.find(@head) { |kw|
          kw.value if kw.is_a?(AST::Keyword) && (kw.value =~ /^[@:]/ || kw.value == '*')
        }

        if !@nick
          if @keyword_nick
            @nick = '*'
          else
            @nick = '.'
            @head << ::Query::NickExpr.nick('.')
          end
        end

        STDERR.puts("QueryAST.new: #{self}, context: #{context.name}")
      end

      def initialize_copy(o)
        super
        @head = @head.dup
        @original_head = @head.dup
        @tail = @tail && @tail.dup
        @original_tail = @tail && @tail.dup
        @join_tables = @join_tables.map(&:dup)
        @join_conditions = @join_conditions.map(&:dup)
        @query_tables = @query_tables.dup if @query_tables
      end

      ##
      # Calls block for this query and all subqueries, in sequence.
      def each_query(&block)
        block.call(self)
        join_tables.each(&block)
        ASTWalker.each_kind(head, :query, &block)
      end

      ##
      # Returns a clone of this AST with the tail predicate as the only
      # predicate.
      def tail_ast
        return nil unless full_tail
        clone = self.dup
        clone.head = self.full_tail.dup
        clone.tail = nil
        clone.instance_variable_set(@full_tail, nil)
        clone
      end

      def query_tables
        @query_tables = Sql::QueryTables.new(@context.table(self.game))
      end

      def add_join_table(j)
        join_tables << j
      end

      ##
      # Returns true if this AST's lookup columns have been autojoined to their
      # lookup tables.
      def autojoined_lookups?
        @autojoined_lookups
      end

      ##
      # Bind all columns that are located in lookup tables as joined columns,
      # and build a final set of query tables (in query_tables).
      def autojoin_lookup_columns!
        @autojoined_lookups = true
        join_tables.each(&:autojoin_lookup_columns!)
        Sql::JoinResolver.resolve(self)
        Sql::ColumnResolver.resolve(self)
      end

      ##
      # Returns the alias for this table when used in a larger query.
      def alias
        @alias || subquery_alias || @context.table_alias
      end

      ##
      # Given a Sql::Field, resolves it as a column either on the context, or on
      # any of the join tables.
      def resolve_column(field)
        join_tables.each { |jt|
          col = jt.resolve_column(field)
          return col if col
        }
        resolve_local_column(field)
      end

      def resolve_local_column(field)
        column = context.resolve_local_column(field)
        if column
          STDERR.puts("#{self}::resolve_local_table_column(#{field}) == #{column}")
          return column.bind(self)
        end

        if grouped?
          # If this is a grouped query, we must recognize the *implicit* count
          # column.
          STDERR.puts("#{self}::resolve_local_table_column(#{field}) == count (synthetic)")
          return Sql::Column.new(context.config, "countI", nil).bind(self)
        end

        STDERR.puts("#{self}::resolve_local_table_column(#{field}) == NOT FOUND (context: #{context.name})")
        # Not my field!
        nil
      end

      ##
      # Returns +true+ if this object is a subquery. Note that subquery_alias
      # and may return nil even if this is a subquery, and that context_name is
      # legimitately nil for subqueries (to imply that they inherit the parent
      # lg/lm context).
      def subquery?
        @subquery
      end

      ##
      # Returns true if this subquery is being used as a table, viz. as a join
      # clause. Returns false for subqueries used in exists clauses, and
      # subqueries that evaluate to a single value result (such as count
      # subqueries) and are used in simple expressions.
      def table_subquery?
        @table_subquery
      end

      ##
      # Returns true if this query exists purely to filter or group by a
      # subquery or subqueries.
      #
      # A query is degenerate if its join_tables is not empty, and if all
      # predicates in the query refer to its join tables (i.e. there are no
      # predicates that refer to the implied main table or to the auto-join
      # table).
      def degenerate?
        !join_tables.empty? && raise("Not implemented")
      end

      ##
      # Returns +true+ if this is a subquery that's being used as an expression;
      # i.e. an expression such as $lm[x=count(*)]=0
      def subquery_expression?
        @subquery_expression
      end

      ##
      # Returns the kind of AST node this is, overrides Term#kind.
      def kind
        :query
      end

      def as_subquery(subquery_alias)
        @subquery_alias = subquery_alias.empty? ? nil : subquery_alias
        @subquery = true
        self
      end

      def resolve_nick(nick)
        nick == '.' ? default_nick : nick
      end

      # The first nick in the query, with . expanded to point at the
      # user requesting.
      def target_nick
        resolve_nick(@nick)
      end

      # The first real nick in the query.
      def real_nick
        @real_nick ||=
          real_nick_in(@original_head) ||
          real_nick_in(@original_tail) || target_nick
      end

      def real_nick_in(tree)
        return nil unless tree
        ASTWalker.find(tree) { |node|
          if node.is_a?(NickExpr) && node.nick.value != '*'
            resolve_nick(node.nick.value)
          elsif node.kind == :keyword && node.value =~ /^[@:]/
            resolve_nick(node.value.gsub(/^[@:]+/, ''))
          end
        }
      end

      def key_value(key)
        self.keys[key]
      end

      def result_prefix_title
        key_value(:title)
      end

      def template_properties
        ::Query::QueryTemplateProperties.properties(self)
      end

      def default_join
        @default_join ||= self.key_value(:join) || CommandContext.default_join
      end

      def stub_message_format
        @stub_message_format ||= self.key_value(:stub)
      end

      def stub_message_template
        @template ||=
          stub_message_format && Tpl::Template.template(stub_message_format)
      end

      def stub_message(nick)
        stub_template = self.stub_message_template
        return Tpl::Template.eval_string(stub_template, self.template_properties) if stub_template

        entities = self.context.entity_name + 's'
        puts "No #{entities} for #{self.description(nick)}."
      end

      ##
      # Returns true if this query is a grouped (s=foo) query.
      def grouped?
        self.summarise
      end

      ##
      # Returns true if this is a grouped query without a group order.
      def needs_group_order?
        !group_order && grouped?
      end

      ##
      # Returns the default group order that should be used when no
      # explicit group order is specified.
      def default_group_order
        (extra && extra.default_group_order) ||
          (summarise && summarise.default_group_order)
      end

      def head_desc(suppress_meta=true)
        stripped_ast_desc(@original_head, true, suppress_meta)
      end

      def tail_desc(suppress_meta=true, slash_prefix=true)
        return '' unless @original_tail
        tail_text = stripped_ast_desc(@original_tail, false, suppress_meta)
        slash_prefix ? "/ " + tail_text : tail_text
      end

      def stripped_ast_desc(ast, suppress_nick=true, suppress_meta=true)
        ast.without { |node|
          (suppress_nick && node.is_a?(Query::NickExpr)) ||
            (suppress_meta && node.meta?)
        }.to_s.strip
      end

      def description(default_nick=self.default_nick,
                      options={})
        texts = []
        texts << self.context_name if options[:context]
        texts << (@nick == '.' ? default_nick : @nick).dup
        desc = self.head_desc(!options[:meta])
        if !desc.empty?
          texts << (!options[:no_parens] ? "(#{desc})" : desc)
        end
        texts << tail_desc(!options[:meta]) if options[:tail]
        texts.join(' ').strip
      end

      def add_option(option)
        @options << option
        opt_key = option.name.to_sym
        old_opt = @opt_map[opt_key]
        @opt_map[opt_key] = old_opt ? old_opt.merge(option) : option
      end

      def option(name)
        @opt_map[name.to_sym]
      end

      def set_option(name, value)
        @opt_map[name.to_sym] = value
      end

      def random?
        option(:random)
      end

      def head
        @head ||= Expr.and()
      end

      def summary?
        summarise || (extra && extra.aggregate?) || self.tail
      end

      def has_sorts?
        !@sorts.empty?
      end

      def reverse_sorts!
        @sorts = @sorts.map { |sort| sort.reverse }
      end

      def needs_sort?
        !summary? && !compound_query?
      end

      def primary_sort
        @sorts.first
      end

      def compound_query?
        @tail
      end

      def transform!(&block)
        self.summarise = block.call(self.summarise) if self.summarise
        if self.sorts
          self.sorts = self.sorts.map { |sort|
            block.call(sort)
          }.compact
        end
        self.group_order = block.call(self.group_order) if self.group_order
        self.extra = block.call(self.extra) if self.extra
        self.head = block.call(self.head)
        @full_tail = block.call(@full_tail) if @full_tail
        self.tail = block.call(self.tail) if self.tail
        self
      end

      def transform_nodes!(&block)
        self.map_nodes_as!(:map_nodes, &block)
      end

      def transform_nodes_breadthfirst!(&block)
        self.map_nodes_as!(:map_nodes_breadthfirst, &block)
      end

      def each_node(&block)
        self.summarise.each_node(&block) if self.summarise
        if self.sorts
          self.sorts.each { |sort|
            sort.each_node(&block)
          }
        end
        self.group_order.each_node(&block) if self.group_order
        self.extra.each_node(&block) if self.extra
        self.head.each_node(&block)
        (self.full_tail || self.tail).each_node(&block) if self.tail
        self
      end

      def map_nodes_as!(mapper, *args, &block)
        self.transform! { |tree|
          ASTWalker.send(mapper, tree, *args, &block)
        }
      end

      def with_context(&block)
        self.context.with(&block)
      end

      def bind_tail!
        @full_tail = @tail && @tail.merge(@head)
      end

      def full_tail
        @full_tail
      end

      def to_s
        is_subquery = subquery?
        pieces = is_subquery ? [] : ["#{context_name}"]
        pieces << @nick if @nick && !is_subquery
        pieces << head.to_query_string(false)
        pieces << @summarise.to_s if summary?
        pieces << group_order.to_s if group_order
        pieces << extra.to_s if extra
        pieces << options.to_s if options && !options.empty?
        pieces << keys.to_s if keys && !keys.empty?
        pieces << sorts[0].to_s if sorts && !sorts.empty?
        pieces << "/" << @tail.to_query_string(false) if @tail
        pieces << "?:" << @filter.to_s if @filter
        text = pieces.select { |x| !x.empty? }.join(' ')
        text = "$#{context_name.to_s}[#{text}]" if subquery?
        text
      end

      ##
      # Returns the SQL clause for the FROM table list.
      def to_table_list_sql
        autojoin_lookup_columns! unless autojoined_lookups?
        query_tables.to_sql
      end

      ##
      # Returns the SQL clause for the FROM table list
      def to_sql
        ast_sql.sql
      end

      ##
      # Returns the values bound to the ? placeholders in the SQL returned by
      # to_sql.
      def sql_values
        ast_sql.sql_values
      end

    private

      def ast_sql
        @ast_sql ||= Sql::QueryASTSQL.new(self)
      end
    end
  end
end
