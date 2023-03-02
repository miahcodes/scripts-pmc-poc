class Campaign
  def initialize(condition, *qualifiers)
    @condition = (condition.to_s + '?').to_sym
    @qualifiers = PostCartAmountQualifier ? [] : [] rescue qualifiers.compact
    @line_item_selector = qualifiers.last unless @line_item_selector
    qualifiers.compact.each do |qualifier|
      is_multi_select = qualifier.instance_variable_get(:@conditions).is_a?(Array)
      if is_multi_select
        qualifier.instance_variable_get(:@conditions).each do |nested_q|
          @post_amount_qualifier = nested_q if nested_q.is_a?(PostCartAmountQualifier)
          @qualifiers << qualifier
        end
      else
        @post_amount_qualifier = qualifier if qualifier.is_a?(PostCartAmountQualifier)
        @qualifiers << qualifier
      end
    end if @qualifiers.empty?
  end

  def qualifies?(cart)
    return true if @qualifiers.empty?
    @unmodified_line_items = cart.line_items.map do |item|
      new_item = item.dup
      new_item.instance_variables.each do |var|
        val = item.instance_variable_get(var)
        new_item.instance_variable_set(var, val.dup) if val.respond_to?(:dup)
      end
      new_item
    end if @post_amount_qualifier
    @qualifiers.send(@condition) do |qualifier|
      is_selector = false
      if qualifier.is_a?(Selector) || qualifier.instance_variable_get(:@conditions).any? { |q| q.is_a?(Selector) }
        is_selector = true
      end rescue nil
      if is_selector
        raise "Missing line item match type" if @li_match_type.nil?
        cart.line_items.send(@li_match_type) do |item|
          next false if item.nil?
          qualifier.match?(item)
        end
      else
        qualifier.match?(cart, @line_item_selector)
      end
    end
  end

  def run_with_hooks(cart)
    before_run(cart) if respond_to?(:before_run)
    run(cart)
    after_run(cart)
  end

  def after_run(cart)
    @discount.apply_final_discount if @discount && @discount.respond_to?(:apply_final_discount)
    revert_changes(cart) unless @post_amount_qualifier.nil? || @post_amount_qualifier.match?(cart)
  end

  def revert_changes(cart)
    cart.instance_variable_set(:@line_items, @unmodified_line_items)
  end
end

class ConditionallyRemoveGateway < Campaign
  def initialize(condition, customer_qualifier, cart_qualifier, li_match_type, line_item_qualifier, gateway_selector)
    super(condition, customer_qualifier, cart_qualifier, line_item_qualifier)
    @li_match_type = (li_match_type.to_s + '?').to_sym
    @gateway_selector = gateway_selector
  end

  def run(gateways, cart)
    return unless @gateway_selector
    gateways.delete_if { |gateway| @gateway_selector.match?(gateway) } if qualifies?(cart)
  end
end

class Qualifier
  def partial_match(match_type, item_info, possible_matches)
    match_type = (match_type.to_s + '?').to_sym
    if item_info.kind_of?(Array)
      possible_matches.any? do |possibility|
        item_info.any? do |search|
          search.send(match_type, possibility)
        end
      end
    else
      possible_matches.any? do |possibility|
        item_info.send(match_type, possibility)
      end
    end
  end

  def compare_amounts(compare, comparison_type, compare_to)
    case comparison_type
      when :greater_than
        return compare > compare_to
      when :greater_than_or_equal
        return compare >= compare_to
      when :less_than
        return compare < compare_to
      when :less_than_or_equal
        return compare <= compare_to
      when :equal_to
        return compare == compare_to
      else
        raise "Invalid comparison type"
    end
  end
end

class CartHasItemQualifier < Qualifier
  def initialize(quantity_or_subtotal, comparison_type, amount, item_selector)
    @quantity_or_subtotal = quantity_or_subtotal
    @comparison_type = comparison_type
    @amount = quantity_or_subtotal == :subtotal ? Money.new(cents: amount * 100) : amount
    @item_selector = item_selector
  end

  def match?(cart, selector = nil)
    raise "Must supply an item selector for the #{self.class}" if @item_selector.nil?
    case @quantity_or_subtotal
      when :quantity
        total = cart.line_items.reduce(0) do |total, item|
          total + (@item_selector&.match?(item) ? item.quantity : 0)
        end
      when :subtotal
        total = cart.line_items.reduce(Money.zero) do |total, item|
          total + (@item_selector&.match?(item) ? item.line_price : Money.zero)
        end
    end
    compare_amounts(total, @comparison_type, @amount)
  end
end

class Selector
  def partial_match(match_type, item_info, possible_matches)
    match_type = (match_type.to_s + '?').to_sym
    if item_info.kind_of?(Array)
      possible_matches.any? do |possibility|
        item_info.any? do |search|
          search.send(match_type, possibility)
        end
      end
    else
      possible_matches.any? do |possibility|
        item_info.send(match_type, possibility)
      end
    end
  end
end

class VariantIdSelector < Selector
  def initialize(match_type, variant_ids)
    @invert = match_type == :not_one
    @variant_ids = variant_ids.map { |id| id.to_i }
  end

  def match?(line_item)
    @invert ^ @variant_ids.include?(line_item.variant.id)
  end
end

class GatewayNameSelector < Selector
  def initialize(match_type, match_condition, names)
    @match_condition = match_condition
    @invert = match_type == :does_not
    @names = names.map(&:downcase)
  end

  def match?(gateway)
    name = gateway.name.downcase
    case @match_condition
      when :match
        return @invert ^ @names.include?(name)
      else
        return @invert ^ partial_match(@match_condition, name, @names)
    end
  end
end

CAMPAIGNS = [
  ConditionallyRemoveGateway.new(
    :all,
    nil,
    CartHasItemQualifier.new(
      :quantity,
      :greater_than,
      0,
      VariantIdSelector.new(
        :is_one,
        ["43702051471382"]
      )
    ),
    :any,
    nil,
    GatewayNameSelector.new(
      :does,
      :match,
      ["Pay by Installments", "Cash on Delivery (COD)"]
    )
  ),
  ConditionallyRemoveGateway.new(
    :all,
    nil,
    CartHasItemQualifier.new(
      :quantity,
      :greater_than,
      0,
      VariantIdSelector.new(
        :is_one,
        ["43702051504150"]
      )
    ),
    :any,
    nil,
    GatewayNameSelector.new(
      :does,
      :match,
      ["Cash on Delivery (COD)", "Bank Deposit", "Paypal"]
    )
  )
].freeze

CAMPAIGNS.each do |campaign|
  campaign.run(Input.payment_gateways, Input.cart)
end

Output.payment_gateways = Input.payment_gateways
