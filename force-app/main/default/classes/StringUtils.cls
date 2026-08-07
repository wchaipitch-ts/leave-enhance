public class StringUtils {
    // Returns a normalized “key Efor a company name.
    // If removeSpacesCompletely = true, the final key has no spaces; otherwise single spaces are preserved.
    public static String normalizeCompanyName(String input, Boolean removeSpacesCompletely) {
        if (String.isBlank(input)) {
            return null;
        }

        // 1) Lowercase + trim
        String s = input.toLowerCase();

        // Replace NBSP and zero‑width space with normal spaces
        // Also remove other invisible zero-width/joiner marks entirely so they don't turn into stray spaces
        s = s.replaceAll('[\u00A0\u200B]', ' '); // NBSP, ZWSP -> spaces
        s = s.replaceAll('[\u200C\u200D\u2060\uFEFF\u034F]', ''); // ZWNJ, ZWJ, WJ, BOM, CGJ -> removed

        s = s.trim();
        if (s.length() == 0) {
            return null;
        }

        // 2) Replace punctuation with spaces: .,;:/\-_'&()[]{}+@!?#
        // Use a character class with hyphen first; escape backslash and brackets, and escape the single quote for Apex string
        s = s.replaceAll('[-.,;:/\\_\'&()\\[\\]{}+@!?#]', ' ');

        // 3) Collapse whitespace ↁEsingle spaces
        s = s.replaceAll('\\s+', ' ').trim();
        if (s.length() == 0) {
            return null;
        }

        // 4) Remove trailing legal suffix chunk (token-based, from the end)
        List<String> tokens = s.split(' ');
        Integer i = tokens.size() - 1;
        Boolean removedAny = false;

        // Single-token suffixes allowed at the very end
        Set<String> singletons = new Set<String>{
            'pcl', 'ltd', 'limited', 'lp', 'partnership', 'corp', 'corporation', 'inc',
            'thailand', 'thai', 'pte'
        };

        while (i >= 0) {
            String t = tokens[i];

            // Multi-token combinations checked first (from the end)
            if (t == 'part' && i > 0 && tokens[i-1] == 'ltd') {
                // "ltd part"
                removedAny = true; i -= 2; continue;
            }
            if (t == 'partnership' && i > 0 && tokens[i-1] == 'limited') {
                // "limited partnership"
                removedAny = true; i -= 2; continue;
            }
            if ((t == 'ltd' || t == 'limited') && i > 0 && tokens[i-1] == 'co') {
                // Guardrail: remove "co" only when immediately before ltd/limited
                removedAny = true; i -= 2; continue;
            }
            if (t == 'limited' && i > 0 && tokens[i-1] == 'company') {
                // "company limited" (and optional leading "public")
                removedAny = true; i -= 2;
                if (i >= 0 && tokens[i] == 'public') {
                    i -= 1; // include optional leading "public"
                }
                continue;
            }

            // Single-token suffixes
            if (singletons.contains(t)) {
                removedAny = true; i -= 1; continue;
            }

            // Guardrail: remove trailing standalone "co" only if it's the final token (i.e., last trailing suffix token)
            if (t == 'co') {
                removedAny = true; i -= 1; continue;
            }

            // Not a suffix token ↁEstop trimming
            break;
        }

        Integer keepEnd = i; // inclusive index to keep
        if (removedAny) {
            if (keepEnd < 0) {
                // Everything trimmed ↁEbecomes empty
                return null;
            }
            List<String> kept = new List<String>();
            for (Integer k = 0; k <= keepEnd; k++) kept.add(tokens[k]);
            s = String.join(kept, ' ');
            // 5) Collapse whitespace again after suffix removal
            s = s.replaceAll('\\s+', ' ').trim();
            if (s.length() == 0) {
                return null;
            }
        }

        // 6) Final key: spaces or no spaces
        if (removeSpacesCompletely == true) {
            s = s.replace(' ', '');
        }
        return s.length() > 0 ? s : null;
    }

    // Backward-compatible method: preserves original return type semantics (empty string on blank input)
    public static String normalizeCompanyName(String name) {
        String out = normalizeCompanyName(name, true);
        return out == null ? '' : out;
    }
}