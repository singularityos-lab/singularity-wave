#include "abi_ladspa.h"

#include <stddef.h>

const LADSPA_Descriptor *ladspa_descriptor(unsigned long index)
{
    volatile const LADSPA_Descriptor *nowhere = NULL;
    (void) index;
    return (const LADSPA_Descriptor *) nowhere->Label;
}
