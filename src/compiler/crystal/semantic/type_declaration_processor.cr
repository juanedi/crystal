module Crystal
  # Here we mix the result of explicit type declarations for
  # global, class and instance variables with the implicit types
  # guessed from assignments to them.
  #
  # If a type is explicit, the guess is not used (it might later
  # give a compile error on incompatible types, on MainVisitor).
  #
  # If the type of an instance variable is implicit a bit more
  # logic is involved since we need to check if a variable is
  # assigned in all of the initialize methods, or if the initializers
  # are defined in a superclass, if super is called, etc.
  struct TypeDeclarationProcessor
    record TypeDeclarationWithLocation,
      type : TypeVar,
      location : Location

    # This captures an initialize info: it's related Def,
    # and which instance variables are assigned. Useful
    # to determine nilable instance variables.
    class InitializeInfo
      getter :def
      property instance_vars : Array(String)?

      def initialize(@def : Def)
      end
    end

    # The types we guess for instance types can be nodes or types.
    # In the case of a generic type we might have:
    #
    # ```
    # class Foo(T)
    #   def foo
    #     @x = T.new
    #   end
    #
    #   def foo
    #     @x = 1
    #   end
    # end
    # ```
    #
    # In the above case we know @x is of type T (but we don't know what
    # T is when instantiated) and Int32 (we know that type). So we
    # keep a list of all types and nodes, and we eventually resolve them
    # all when a generic type is instantiated.
    class InstanceVarTypeInfo
      getter type_vars
      property outside_def

      def initialize
        @type_vars = [] of TypeVar
        @outside_def = false
      end
    end

    record NilableInstanceVar,
      info : InitializeInfo,
      name : String

    def initialize(@program : Program)
      # The type of instance variables. The last one wins.
      #
      # In the case of instance variables we can't always match a type
      # because they might be declared in generic types, for example:
      #
      # ```
      # class Foo(T)
      #   @x : T
      # end
      # ```
      #
      # In that case we remember that @x has a T node associated with it,
      # and only resolve it when instantiating the generic type.
      @explicit_instance_vars = {} of Type => Hash(String, TypeDeclarationWithLocation)

      # The types we guess for instance vars, when not explicit
      @guessed_instance_vars = {} of Type => Hash(String, InstanceVarTypeInfo)

      # Info related to a type's initialize methods
      @initialize_infos = {} of Type => Array(InitializeInfo)

      # Instance variables that are initialized outside a method (at the class level)
      @instance_vars_outside = {} of Type => Array(String)

      # Instance vars that are determined to be non-nilable because
      # they are initialized in all of the initialize methods
      @non_nilable_instance_vars = {} of Type => Array(String)

      # Nilable variables there were detected to not be initilized in an initialize,
      # but a superclass does initialize it. It's only an error if the explicit/guessed
      # type is not nilable itself.
      @nilable_instance_vars = {} of Type => Hash(String, InitializeInfo)
    end

    def process(node)
      # First check type declarations
      visitor = TypeDeclarationVisitor.new(@program, @explicit_instance_vars)
      node.accept visitor

      # Use the last type found for global variables to declare them
      visitor.globals.each do |name, type|
        declare_meta_type_var(@program.global_vars, @program, name, type)
      end

      # Use the last type found for class variables to declare them
      visitor.class_vars.each do |owner, vars|
        vars.each do |name, type|
          declare_meta_type_var(owner.class_vars, owner, name, type)
        end
      end

      # Now use several syntactic rules to infer the types of
      # variables that don't have an explicit type set
      visitor = TypeGuessVisitor.new(@program, @explicit_instance_vars,
        @guessed_instance_vars, @initialize_infos, @instance_vars_outside)
      node.accept visitor

      # Process global variables
      visitor.globals.each do |name, info|
        declare_meta_type_var(@program.global_vars, @program, name, info)
      end

      # Process class variables
      visitor.class_vars.each do |owner, vars|
        vars.each do |name, info|
          declare_meta_type_var(owner.class_vars, owner, name, info)
        end
      end

      compute_non_nilable_instance_vars

      process_instance_vars_declarations

      # Check that instance vars that weren't initialized in an initialize,
      # but a superclass does initialize then, are nilable, and if not
      # give an error
      check_nilable_instance_vars

      node
    end

    private def declare_meta_type_var(vars, owner, name, type : Type)
      var = MetaTypeVar.new(name)
      var.owner = owner
      var.type = type
      var.bind_to(var)
      var.freeze_type = type
      vars[name] = var
      var
    end

    private def declare_meta_type_var(vars, owner, name, info : TypeGuessVisitor::TypeInfo)
      type = info.type
      type = Type.merge!(type, @program.nil) unless info.outside_def
      declare_meta_type_var(vars, owner, name, type)
    end

    private def declare_meta_type_var(vars, owner, name, info : TypeDeclarationWithLocation)
      var = declare_meta_type_var(vars, owner, name, info.type as Type)
      var.location = info.location

      # If the variable is gueseed to be nilable because it is not initialized
      # in all of the initialize methods, and the explicit type is not nilable,
      # give an error right now
      if !var.type.includes_type?(@program.nil)
        if nilable_instance_var?(owner, name)
          var.raise "instance variable '#{name}' of #{owner} was not initialized in all of the 'initialize' methods, rendering it nilable"
        end
      end

      var
    end

    private def process_instance_vars_declarations
      owners = @explicit_instance_vars.keys + @guessed_instance_vars.keys
      owners.uniq!

      # We traverse types from the top of the hierarchy, processing
      # explicit vars first and then guessed ones. We must do this at the
      # same type to avoid declaring an explicit type in a subclass and
      # then find out the variable belongs to a superclass.
      owners = sort_types_by_depth(owners)
      owners.each do |owner|
        vars = @explicit_instance_vars[owner]?
        vars.try &.each do |name, type_decl|
          process_owner_instance_var_declaration(owner, name, type_decl)
        end

        vars = @guessed_instance_vars[owner]?
        vars.try &.each do |name, type_decl|
          process_owner_guessed_instance_var_declaration(owner, name, type_decl)
        end
      end
    end

    private def process_owner_instance_var_declaration(owner, name, type_decl)
      case owner
      when NonGenericClassType
        # Check if a superclass already defined this variable
        supervar = owner.lookup_instance_var_with_owner?(name)
        if supervar
          # Redeclaring a variable with the same type is OK
          unless supervar.instance_var.type.same?(type_decl.type)
            raise TypeException.new("instance variable '#{name}' of #{supervar.owner}, with #{owner} < #{supervar.owner}, is already declared as #{supervar.instance_var.type}", type_decl.location)
          end
        else
          declare_meta_type_var(owner.instance_vars, owner, name, type_decl)
        end
      when NonGenericModuleType
        # Transfer this declaration to including types, recursively
        owner.raw_including_types.try &.each do |including_type|
          process_owner_instance_var_declaration(including_type, name, type_decl)
        end
      when GenericClassType
        # If the variable is guessed to be nilable because it's not initialized in all
        # of the initialize method, use a syntactic heuristic to check that the declared type
        # is or not non-nilable.
        if nilable_instance_var?(owner, name)
          if !has_syntax_nil?(type_decl.type)
            raise TypeException.new("instance variable '#{name}' of #{owner} was not initialized in all of the 'initialize' methods, rendering it nilable", type_decl.location)
          end
        end

        owner.declare_instance_var(name, type_decl.type)
      when GenericModuleType
        owner.declare_instance_var(name, type_decl.type)
        check_non_nilable_for_generic_module(owner, name, type_decl)
      end
    end

    private def check_non_nilable_for_generic_module(owner, name, type_decl)
      case owner
      when GenericModuleType
        owner.inherited.try &.each do |inherited|
          check_non_nilable_for_generic_module(inherited, name, type_decl)
        end
      when NonGenericModuleType
        owner.raw_including_types.try &.each do |inherited|
          check_non_nilable_for_generic_module(inherited, name, type_decl)
        end
      when NonGenericClassType
        var = owner.lookup_instance_var_with_owner(name).instance_var
        if !var.type.includes_type?(@program.nil)
          if nilable_instance_var?(owner, name)
            var.raise "instance variable '#{name}' of #{owner} was not initialized in all of the 'initialize' methods, rendering it nilable"
          end
        end
      when GenericClassType
        if nilable_instance_var?(owner, name)
          if !has_syntax_nil?(type_decl.type)
            raise TypeException.new("instance variable '#{name}' of #{owner} was not initialized in all of the 'initialize' methods, rendering it nilable", type_decl.location)
          end
        end
      end
    end

    private def has_syntax_nil?(node)
      case node
      when Union
        node.types.any? { |type| has_syntax_nil?(type) }
      when Path
        # TODO: we should actually check that this resolves to the top-level Nil type
        node.names.size == 1 && node.names.first == "Nil"
      else
        false
      end
    end

    private def process_owner_guessed_instance_var_declaration(owner, name, type_info)
      case owner
      when NonGenericClassType
        # If a superclass already defines this variable we ignore
        # the guessed type information for subclasses
        supervar = owner.lookup_instance_var_with_owner?(name)
        return if supervar

        type = Type.merge!(type_info.type_vars.map { |t| t as Type })
        nilable = false

        if nilable_instance_var?(owner, name)
          old_type = type
          type = Type.merge!(type, @program.nil)
          nilable = true if type != old_type
        end

        # If the only type that we were able to infer was nil, it's the same
        # as not being able to infer anything (having a variable of just
        # Nil is not useful and is the same as not having it at all, at
        # least for non-generic types)
        if type.nil_type?
          return
        end

        var = declare_meta_type_var(owner.instance_vars, owner, name, type)
        if nilable
          var.nil_reason = NilReason.new(name, :not_in_initialize, scope: owner)
        end
      when NonGenericModuleType
        # Transfer this guess to including types, recursively
        owner.raw_including_types.try &.each do |including_type|
          process_owner_guessed_instance_var_declaration(including_type, name, type_info)
        end
      when GenericClassType
        if nilable_instance_var?(owner, name)
          type_info.type_vars << @program.nil
        end

        # Same as above, only Nil makes no sense
        if type_info.type_vars.all? { |t| t.is_a?(NilType) }
          return
        end

        owner.declare_instance_var(name, type_info.type_vars)
      when GenericModuleType
        if nilable_instance_var?(owner, name)
          type_info.type_vars << @program.nil
        end

        owner.declare_instance_var(name, type_info.type_vars)
      end
    end

    private def nilable_instance_var?(owner, name)
      non_nilable_vars = @non_nilable_instance_vars[owner]?
      !non_nilable_vars || (non_nilable_vars && !non_nilable_vars.includes?(name))
    end

    private def compute_non_nilable_instance_vars
      owners = sort_types_by_depth(@initialize_infos.keys).uniq!

      owners.each do |owner|
        # Compute nilable variables because of initialize
        infos = find_initialize_infos(owner)

        if infos
          non_nilable = compute_non_nilable_instance_vars_multi(owner, infos)
        end

        # We must also take into account those variables that are
        # initialized outside of an initializer
        non_nilable_outisde = compute_non_nilable_outside(owner)

        # And add them all into one array
        non_nilable = merge_non_nilable_vars(non_nilable, non_nilable_outisde)

        if non_nilable
          @non_nilable_instance_vars[owner] = non_nilable
        end
      end
    end

    private def merge_non_nilable_vars(v1, v2)
      if v1
        if v2
          v1 = (v1 + v2).uniq!
        end
      elsif v2
        v1 = v2
      end
      v1
    end

    private def compute_non_nilable_instance_vars_multi(owner, infos)
      # Get ancestor's non-nilable variables
      ancestor = owner.ancestors.first?
      case ancestor
      when IncludedGenericModule
        ancestor = ancestor.module
      when InheritedGenericClass
        ancestor = ancestor.extended_class
      end
      if ancestor
        ancestor_non_nilable = @non_nilable_instance_vars[ancestor]?
      end

      # If the ancestor has non-nilable instance vars, check that all initialize either call
      # super or assign all of those variables
      if ancestor_non_nilable
        infos.each do |info|
          unless info.def.calls_super
            ancestor_non_nilable.each do |name|
              # If the variable is initialized outside, it's OK
              next if initialized_outside?(owner, name)

              unless info.try &.instance_vars.try &.includes?(name)
                # Rememebr that this variable wasn't initialized here, and later error
                # if it turns out to be non-nilable
                nilable_vars = @nilable_instance_vars[owner] ||= {} of String => InitializeInfo
                nilable_vars[name] = info
              end
            end
          end
        end
      end

      # Get all instance vars assigned in all the initialize methods
      all_instance_vars = [] of String
      infos.each do |info|
        info.instance_vars.try { |ivars| all_instance_vars.concat(ivars) }
      end
      all_instance_vars.uniq!

      # Then check which ones are assigned in all of them
      non_nilable = [] of String
      all_instance_vars.each do |instance_var|
        all_assigned = infos.all? do |info|
          # If an initialize calls another initialize, consider it like it initializes
          # all instance vars, because the other initialize will have to do that
          info.def.calls_initialize || info.try(&.instance_vars.try(&.includes?(instance_var)))
        end
        if all_assigned
          non_nilable << instance_var
        end
      end

      merge_non_nilable_vars(non_nilable, ancestor_non_nilable)
    end

    private def initialized_outside?(owner, name)
      if @instance_vars_outside[owner]?.try &.includes?(name)
        return true
      end

      owner.ancestors.any? do |ancestor|
        @instance_vars_outside[ancestor]?.try &.includes?(name)
      end
    end

    private def compute_non_nilable_outside(owner)
      non_nilable_outisde = nil
      non_nilable_outisde = compute_non_nilable_outside_single(owner, non_nilable_outisde)
      owner.ancestors.each do |ancestor|
        non_nilable_outisde = compute_non_nilable_outside_single(ancestor, non_nilable_outisde)
      end
      non_nilable_outisde
    end

    private def compute_non_nilable_outside_single(owner, non_nilable_outisde)
      if vars = @instance_vars_outside[owner]?
        non_nilable_outisde ||= [] of String
        vars.each do |name|
          non_nilable_outisde << name unless non_nilable_outisde.includes?(name)
        end
      end
      non_nilable_outisde
    end

    private def find_initialize_infos(owner)
      # Find the first type in the ancestor chain, including self,
      # that defines an initialize method
      infos = @initialize_infos[owner]?
      return infos if infos && !infos.empty?

      owner.ancestors.each do |ancestor|
        infos = @initialize_infos[ancestor]?
        return infos if infos && !infos.empty?
      end

      nil
    end

    private def check_nilable_instance_vars
      @nilable_instance_vars.each do |owner, vars|
        vars.each do |name, info|
          case owner
          when NonGenericClassType
            ivar = owner.lookup_instance_var_with_owner(name)
            unless ivar.instance_var.type.includes_type?(@program.nil)
              info.def.raise "this 'initialize' doesn't initialize instance variable '#{name}' of #{ivar.owner}, with #{owner} < #{ivar.owner}, rendering it nilable"
            end
          when GenericClassType
            type_vars = owner.declared_instance_vars.not_nil![name]
            unless type_vars.any? { |type_var| has_syntax_nil?(type_var) }
              info.def.raise "this 'initialize' doesn't initialize ancestor instance variable '#{name}', rendering it nilable"
            end
          end
        end
      end
    end

    private def sort_types_by_depth(types)
      # We sort types. We put modules first, because if these declare types
      # of instance variables we want them declared in including types.
      # Then we sort other types by depth, so we declare types first in
      # superclass and then in subclasses.
      types.sort! do |t1, t2|
        if t1.module?
          if t2.module?
            t1.object_id <=> t2.object_id
          else
            -1
          end
        elsif t2.module?
          1
        else
          t1.depth <=> t2.depth
        end
      end
    end
  end
end
