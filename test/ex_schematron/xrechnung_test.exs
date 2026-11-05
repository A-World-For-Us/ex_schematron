defmodule ExSchematron.XRechnungTest do
  @moduledoc """
  The KoSIT XRechnung CII schematron, compiled as released (see
  test/fixtures/schematron/xrechnung/VERSION). It exercises what no FNFE
  schematron does: an include (common.sch, a pattern of constants), PEPPOL
  helper functions no rule calls, some with bodies this library does not
  support, and a function reading a global (xr:checkIBAN reads
  $XR-IBAN-REGEX from common.sch).
  """
  use ExUnit.Case, async: true

  defmodule Validator do
    use ExSchematron, sch: Path.expand("../fixtures/schematron/xrechnung/cii/XRechnung-CII-validation.sch", __DIR__)
  end

  @xrechnung_id "urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0"

  defp invoice(guideline_id, payment_means) do
    """
    <rsm:CrossIndustryInvoice
      xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
      xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100">
      <rsm:ExchangedDocumentContext>
        <ram:GuidelineSpecifiedDocumentContextParameter><ram:ID>#{guideline_id}</ram:ID></ram:GuidelineSpecifiedDocumentContextParameter>
      </rsm:ExchangedDocumentContext>
      <rsm:SupplyChainTradeTransaction>
        <ram:ApplicableHeaderTradeSettlement>#{payment_means}</ram:ApplicableHeaderTradeSettlement>
      </rsm:SupplyChainTradeTransaction>
    </rsm:CrossIndustryInvoice>
    """
  end

  defp credit_transfer(iban) do
    """
    <ram:SpecifiedTradeSettlementPaymentMeans>
      <ram:TypeCode>58</ram:TypeCode>
      <ram:PayeePartyCreditorFinancialAccount><ram:IBANID>#{iban}</ram:IBANID></ram:PayeePartyCreditorFinancialAccount>
    </ram:SpecifiedTradeSettlementPaymentMeans>
    """
  end

  defp direct_debit(iban) do
    """
    <ram:SpecifiedTradeSettlementPaymentMeans>
      <ram:TypeCode>59</ram:TypeCode>
      <ram:PayerPartyDebtorFinancialAccount><ram:IBANID>#{iban}</ram:IBANID></ram:PayerPartyDebtorFinancialAccount>
    </ram:SpecifiedTradeSettlementPaymentMeans>
    """
  end

  defp rules(xml), do: xml |> Validator.validate() |> MapSet.new(& &1.rule)

  defp runtime_errors(xml), do: xml |> Validator.validate() |> Enum.filter(&(&1.type == :error))

  test "the specification identifier is checked against the constants of the included common.sch" do
    refute "BR-DE-21" in rules(invoice(@xrechnung_id, credit_transfer("DE89370400440532013000")))
    assert "BR-DE-21" in rules(invoice("urn:cen.eu:en16931:2017", credit_transfer("DE89370400440532013000")))
  end

  test "BR-DE-19 runs the mod-97 IBAN checksum, not the structural regex alone" do
    for valid <- ["DE89370400440532013000", "DE89 3704 0044 0532 0130 00", "GB82WEST12345698765432"] do
      refute "BR-DE-19" in rules(invoice(@xrechnung_id, credit_transfer(valid))), valid
    end

    # Well-formed, wrong checksum; then malformed.
    for invalid <- ["DE89370400440532013001", "DE00ABC"] do
      assert "BR-DE-19" in rules(invoice(@xrechnung_id, credit_transfer(invalid))), invalid
    end
  end

  test "BR-DE-20 checks the debited account the same way" do
    refute "BR-DE-20" in rules(invoice(@xrechnung_id, direct_debit("DE89370400440532013000")))
    assert "BR-DE-20" in rules(invoice(@xrechnung_id, direct_debit("DE89370400440532013001")))
  end

  test "no rule hits a runtime error" do
    for xml <- [
          invoice(@xrechnung_id, credit_transfer("DE89370400440532013000")),
          invoice(@xrechnung_id, direct_debit("not an iban"))
        ] do
      assert runtime_errors(xml) == []
    end
  end
end
