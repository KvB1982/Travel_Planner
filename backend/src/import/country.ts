/**
 * Country names as one German spelling, whatever the page or the model wrote:
 * "Croatia", "HR", "Hrvatska" and "Kroatien" must not become four groups in a list.
 */
const CODES = "AD AE AF AG AL AM AO AR AT AU AZ BA BB BD BE BF BG BH BJ BM BN BO BR BS BT BW BY BZ CA CD CG CH CI CL CM CN CO CR CU CV CY CZ DE DJ DK DM DO DZ EC EE EG ER ES ET FI FJ FO FR GA GB GD GE GH GI GL GM GN GQ GR GT GW GY HK HN HR HT HU ID IE IL IN IQ IR IS IT JM JO JP KE KG KH KM KR KW KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MG MK ML MM MN MO MR MT MU MV MW MX MY MZ NA NE NG NI NL NO NP NZ OM PA PE PG PH PK PL PR PT PY QA RE RO RS RU RW SA SC SD SE SG SI SK SL SM SN SO SR SV SY SZ TD TG TH TJ TN TR TT TW TZ UA UG US UY UZ VA VE VN XK YE ZA ZM ZW".split(" ");

const key = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z]/g, "");

const table = new Map<string, string>();
{
  const german = new Intl.DisplayNames(["de"], { type: "region" });
  for (const code of CODES) {
    const name = german.of(code);
    if (!name || name === code) continue;
    table.set(key(code), name);
    // The country's name in the languages listings commonly come in, and in its own.
    for (const locale of ["de", "en", "fr", "it", "es", "nl", "da", "sv", "pl", code.toLowerCase()]) {
      try {
        const other = new Intl.DisplayNames([locale], { type: "region" }).of(code);
        if (other && other !== code && !table.has(key(other))) table.set(key(other), name);
      } catch {
        // No such locale: nothing to add.
      }
    }
  }
  const extra: Record<string, string> = { hrvatska: "HR", usa: "US", uk: "GB", england: "GB", greatbritain: "GB", grossbritannien: "GB", holland: "NL", czechia: "CZ", tschechien: "CZ", turkey: "TR", espana: "ES", italia: "IT", ellada: "GR", hellas: "GR", osterreich: "AT", schweiz: "CH", suisse: "CH", svizzera: "CH", danmark: "DK", sverige: "SE", norge: "NO", polska: "PL", magyarorszag: "HU", slovenija: "SI", crnagora: "ME", shqiperia: "AL", deutschland: "DE", nederland: "NL", belgie: "BE", belgique: "BE", portugal: "PT", france: "FR" };
  for (const [k, code] of Object.entries(extra)) table.set(k, german.of(code) ?? code);
}

export function germanCountry(raw: string | null): string | null {
  if (!raw) return raw;
  const trimmed = raw.trim();
  return table.get(key(trimmed)) ?? trimmed;
}
